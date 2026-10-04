#!/usr/bin/env bash
set -euo pipefail
cd "${RELEASE_WORK:?}"
pnpm install --frozen-lockfile
case ${1:?} in
    desktop)
        pnpm run ci
        electron_arch=x64
        [[ $RELEASE_ARCH != aarch64 ]] || electron_arch=arm64
        package_name=tensamin
        [[ $TENSAMIN_CHANNEL == stable ]] || package_name="tensamin-$TENSAMIN_CHANNEL"
        pnpm --dir apps/electron exec electron-builder --config electron-builder.config.cjs \
            --config.deb.packageName="$package_name" --config.rpm.packageName="$package_name" \
            --linux --"$electron_arch" --publish never
        pnpm run copy-releases
        for asset in releases/*; do
            [[ $(basename "$asset") == SHA256SUMS ]] && continue
            name=$(basename "$asset")
            [[ $name != electron-release-metadata.json ]] || name="electron-release-metadata-$RELEASE_ARCH.json"
            cp "$asset" "$RELEASE_OUT/$name"
        done
        ;;
    android)
        : "${ANDROID_KEYSTORE_BASE64:?}" "${ANDROID_KEY_ALIAS:?}" "${ANDROID_KEY_PASSWORD:?}" "${ANDROID_STORE_PASSWORD:?}"
        umask 077
        printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 --decode > release.keystore
        # Gradle resolves the keystore properties relative to the client root.
        printf 'storeFile=release.keystore\nkeyAlias=%s\nkeyPassword=%s\nstorePassword=%s\n' \
            "$ANDROID_KEY_ALIAS" "$ANDROID_KEY_PASSWORD" "$ANDROID_STORE_PASSWORD" > keystore.properties
        trap 'rm -f release.keystore keystore.properties' EXIT
        cargo test --locked --manifest-path apps/tauri/src-tauri/Cargo.toml
        pnpm run build:mobile
        apk=apps/tauri/src-tauri/gen/android/app/build/outputs/apk/universal/release/app-universal-release.apk
        "$ANDROID_HOME/build-tools/35.0.0/apksigner" verify --verbose "$apk"
        cp "$apk" "$RELEASE_OUT/Tensamin-$TENSAMIN_RELEASE_TAG.apk"
        ;;
    *) exit 2 ;;
esac
