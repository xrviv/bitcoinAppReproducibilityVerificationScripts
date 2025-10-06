#!/bin/bash

repo=https://github.com/horizontalsystems/unstoppable-wallet-android
tag=$versionName
builtApk=$workDir/app/app/build/outputs/apk/release/app-release-unsigned.apk

test() {
 cp "$TEST_ANDROID_DIR/io.horizontalsystems.bankwallet.dockerfile" . && \
 podman build -t unstoppable-build -f io.horizontalsystems.bankwallet.dockerfile . && \
 podman run -it --volume $PWD:/mnt --workdir /mnt --memory=12g --rm unstoppable-build bash -x -c \
     'apt update && DEBIAN_FRONTEND=noninteractive apt install openjdk-17-jdk --yes && ./gradlew clean :app:assembleRelease'
}
