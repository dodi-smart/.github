plugins {
    kotlin("multiplatform") version "2.2.20"
}

kotlin {
    jvm()
    // Disabled on a Linux host, as on the Linux PR runners: the iOS half is
    // the macOS job's.
    iosSimulatorArm64()

    sourceSets {
        commonMain.dependencies {
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
        }
    }
}
