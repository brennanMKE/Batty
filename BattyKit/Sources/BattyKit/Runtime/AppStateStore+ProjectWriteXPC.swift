// AppStateStore+ProjectWriteXPC.swift

import BattyXPCCore
import Foundation

extension AppStateStore {
    /// The `projectCreate` verb. Never overwrites, never pre-approves
    /// startup commands, and saves nothing when any step fails.
    func createProjectForXPC(_ request: ProjectWriteRequest) async -> CLIOutcome<ProjectWriteReply> {
        await writeProjectForXPC(request, editing: nil)
    }

    /// The `projectEdit` verb: only the given fields change, then open
    /// Sessions pick them up as they do after an editor save.
    func editProjectForXPC(_ request: ProjectWriteRequest) async -> CLIOutcome<ProjectWriteReply> {
        if let problem = projectFileProblemForXPC() { return .failure(problem) }
        let target = (request.target ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored = UUID(uuidString: target).flatMap(projectStore.project(id:)) ?? projectStore.project(named: target) else {
            return .failure(Self.unknownProjectMessage(target, names: projectStore.projects.map(\.name)))
        }
        return await writeProjectForXPC(request, editing: stored)
    }

    private func writeProjectForXPC(_ request: ProjectWriteRequest, editing stored: Project?) async -> CLIOutcome<ProjectWriteReply> {
        if let problem = projectFileProblemForXPC() { return .failure(problem) }

        var base: Project
        var rootNeedsChoosing = false
        var captureNotes: [ProjectEditorField: String] = [:]
        if case .fromSession(let id) = request.layout {
            guard let sessionID = id ?? request.callerSessionID ?? focusedSessionIDFallback(), let session = session(id: sessionID) else {
                return .failure("unknown session id")
            }
            let draft = SaveSessionAsProject.draft(for: session, destination: stored.map { .update($0.id) } ?? .newProject, store: self)
            if var kept = stored {
                kept.layout = draft.makeProject().layout
                base = kept
            } else {
                base = draft.makeProject()
                base.isShared = false
                base.approvedCommandsHash = nil
                rootNeedsChoosing = draft.rootNeedsChoosing && request.rootPath == nil
                captureNotes = draft.captureNotes
            }
        } else if let stored {
            base = stored
        } else {
            base = Project(name: request.name ?? "", rootPath: request.rootPath ?? "", runStartupCommandsOnOpen: true, isShared: false)
        }

        var document: ProjectLayoutDocument?
        if case .document(let value) = request.layout {
            do { try value.check() } catch { return .failure(error.message) }
            document = value
        }

        var references = document?.imageReferences() ?? []
        let projectReference: ProjectBackgroundReference?? = switch request.background {
        case nil: nil
        case .none?: .some(nil)
        case .hosted(let set, let title)?: .hosted(set: set, title: title)
        case .hostedID(let id)?: .hostedID(id)
        case .myImage(let digest)?: .myImage(digest: digest)
        case .file(let path)?: .file(path)
        }
        if case .some(.some(let reference)) = projectReference, !references.contains(reference) { references.append(reference) }
        var resolved: [ProjectBackgroundReference: ResolvedProjectImage] = [:]
        switch await resolveProjectImages(references) {
        case .success(let images): resolved = images
        case .failure(let message): return .failure(message)
        }

        let imagePath: String?? = switch projectReference {
        case nil: nil
        case .some(nil): .some(nil)
        case .some(.some(let reference)): .some(resolved[reference]?.path)
        }
        var project: Project
        do {
            project = try ProjectWriteBuilder.apply(request, to: base, imagePath: imagePath)
            if let document {
                project.layout = try document.makeLayout(images: resolved)
            }
            if let commands = request.startupCommands {
                project.layout = try ProjectWriteBuilder.assign(startupCommands: commands, to: project.layout)
            }
        } catch let error as ProjectWriteError {
            return .failure(error.message)
        } catch let error as ProjectLayoutMappingError {
            return .failure(error.message)
        } catch {
            return .failure(error.localizedDescription)
        }

        if let clash = projectStore.projects.first(where: { $0.id != project.id && $0.name.lowercased() == project.name.lowercased() }) {
            return .failure("a Project named \"\(clash.name)\" already exists")
        }
        let projectBackgrounds = self.projectBackgrounds
        let validation = ProjectValidator.validate(
            project, others: projectStore.projects, rootNeedsChoosing: rootNeedsChoosing,
            directoryExists: ProjectEditorViewModel.fileSystemDirectoryExists,
            imageState: { projectBackgrounds.imageState(ofPath: $0) },
            captureNotes: captureNotes)
        if !validation.isValid {
            return .failure(Self.lines(validation.errors).joined(separator: "; "))
        }
        do {
            try projectStore.upsert(project)
        } catch let error as ProjectStoreError {
            return .failure(ProjectEditorViewModel.message(for: error))
        } catch {
            return .failure(error.localizedDescription)
        }
        let saved = projectStore.project(id: project.id) ?? project
        var appliesOnNextOpen: [String] = []
        if let stored {
            applyProjectSave(previous: stored, saved: saved)
            if stored.layout != saved.layout { appliesOnNextOpen = ["layout"] }
        }
        return .success(ProjectWriteReply(
            id: saved.id, name: saved.name, rootPath: saved.rootPath,
            paneCount: saved.layout.paneCount, tabCount: saved.layout.tabCount,
            created: stored == nil, warnings: Self.lines(validation.warnings), appliesOnNextOpen: appliesOnNextOpen))
    }

    private static func lines(_ messages: [ProjectEditorField: String]) -> [String] {
        messages.map { "\($0.key.cliPath): \($0.value)" }.sorted()
    }

    /// Takes the picker's route: a Background Sets image is fetched into
    /// the Hosted folder and a My Images image found by digest, and either
    /// is copied into the Project background folder; a local file is
    /// imported. Any failure fails the whole write.
    private func resolveProjectImages(_ references: [ProjectBackgroundReference]) async -> CLIOutcome<[ProjectBackgroundReference: ResolvedProjectImage]> {
        guard !references.isEmpty else { return .success([:]) }
        let images = backgroundImages
        let hosted = images.hosted
        let importer = projectBackgrounds.importer
        if references.contains(where: { if case .myImage = $0 { false } else if case .file = $0 { false } else { true } }) {
            await hosted.catalogsForCLI()
        }
        if references.contains(where: { if case .myImage = $0 { true } else { false } }) {
            await images.refresh()
        }
        var hostedImages: [ProjectBackgroundReference: HostedBackgroundImage] = [:]
        for reference in references {
            let lookup: CLIOutcome<HostedBackgroundImage>
            switch reference {
            case .hostedID(let id): lookup = hosted.hostedImage(id: id)
            case .hosted(let set, let title): lookup = hosted.hostedImage(set: set, title: title)
            case .myImage, .file: continue
            }
            switch lookup {
            case .success(let image): hostedImages[reference] = image
            case .failure(let message): return .failure(message)
            }
        }
        var result: [ProjectBackgroundReference: ResolvedProjectImage] = [:]
        for reference in references {
            let copy: String?
            switch reference {
            case .hostedID, .hosted:
                guard let image = hostedImages[reference] else { continue }
                guard let path = await hosted.select(image).value else {
                    return .failure("couldn't download \"\(image.title)\"; nothing was saved")
                }
                copy = await importer.adoptImage(path: path, from: images.pickSources)
                if copy == nil { return .failure("couldn't copy \"\(image.title)\" into the Project; nothing was saved") }
            case .myImage(let digest):
                guard let entry = images.entries.first(where: { $0.digest == digest }) else {
                    return .failure("no My Images image has the digest \"\(digest)\"; run `batty background list` to see them")
                }
                copy = await importer.adoptImage(path: entry.path, from: images.pickSources)
                if copy == nil { return .failure("couldn't copy \"\(entry.name)\" into the Project; nothing was saved") }
            case .file(let path):
                do {
                    copy = try await importer.importImage(from: URL(fileURLWithPath: path))
                } catch {
                    return .failure("couldn't use \(path) as a background: \(error.localizedDescription); nothing was saved")
                }
            }
            guard let copy else { continue }
            result[reference] = ResolvedProjectImage(path: copy, image: tabImageIdentity.identity(forPath: copy, keeping: nil))
        }
        return .success(result)
    }
}
