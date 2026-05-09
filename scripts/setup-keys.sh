#!/usr/bin/env zsh

xcrun notarytool store-credentials "Batty-notary" \
    --key ~/.appstoreconnect/AuthKey_DWLP54ACTJ.p8 \
    --key-id DWLP54ACTJ \
    --issuer 69a6de6e-9f19-47e3-e053-5b8c7c11a4d1
