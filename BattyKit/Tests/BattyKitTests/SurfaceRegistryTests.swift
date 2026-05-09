// SurfaceRegistryTests.swift

import Foundation
import Testing
@testable import BattyKit

struct SurfaceRegistryTests {

    private func fakeSurface(_ address: Int) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(bitPattern: address)!
    }

    @Test func registerAssignsAUniqueIDPerCall() {
        let registry = SurfaceRegistry()
        let a = registry.register(fakeSurface(0xA0A0_A0A0))
        let b = registry.register(fakeSurface(0xB0B0_B0B0))
        #expect(a != b)
        #expect(registry.count == 2)
    }

    @Test func surfaceForRetrievesTheRegisteredHandle() {
        let registry = SurfaceRegistry()
        let handle = fakeSurface(0xC0C0_C0C0)
        let id = registry.register(handle)
        #expect(registry.surface(for: id) == handle)
    }

    @Test func surfaceForReturnsNilForUnknownID() {
        let registry = SurfaceRegistry()
        registry.register(fakeSurface(0xD0D0_D0D0))
        #expect(registry.surface(for: UUID()) == nil)
    }

    @Test func unregisterRemovesAndReturnsHandle() {
        let registry = SurfaceRegistry()
        let handle = fakeSurface(0xE0E0_E0E0)
        let id = registry.register(handle)

        let removed = registry.unregister(id)
        #expect(removed == handle)
        #expect(registry.surface(for: id) == nil)
        #expect(registry.contains(id) == false)
        #expect(registry.count == 0)
    }

    @Test func unregisterReturnsNilForUnknownID() {
        let registry = SurfaceRegistry()
        #expect(registry.unregister(UUID()) == nil)
    }

    @Test func containsReflectsRegistration() {
        let registry = SurfaceRegistry()
        let id = registry.register(fakeSurface(0xF0F0_F0F0))
        #expect(registry.contains(id))
        #expect(!registry.contains(UUID()))
    }

    @Test func idsExposesEveryRegisteredID() {
        let registry = SurfaceRegistry()
        let a = registry.register(fakeSurface(0x1111_1111))
        let b = registry.register(fakeSurface(0x2222_2222))
        let c = registry.register(fakeSurface(0x3333_3333))
        #expect(registry.ids == [a, b, c])
    }

    @Test func registryRetainsHandlesAcrossUnrelatedRemovals() {
        let registry = SurfaceRegistry()
        let kept = registry.register(fakeSurface(0xAAAA_AAAA))
        let throwaway = registry.register(fakeSurface(0xBBBB_BBBB))
        registry.unregister(throwaway)
        #expect(registry.surface(for: kept) != nil)
        #expect(registry.count == 1)
    }
}
