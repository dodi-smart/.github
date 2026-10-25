# Self-test fixtures

Small projects the `tools` job in `self-test.yml` runs the real SBOM generators
and osv-scanner against, so a version bump that stops reading one of them fails
here rather than in a release. `__fixtures__` keeps Renovate out of them (its
recommended preset ignores the name), so the pinned versions stay what the
assertions expect.

- `gradle/`: a JVM build that applies the CycloneDX Gradle plugin.
- `kmm/`: a Kotlin Multiplatform build without it (cdxgen's path), with the
  iOS app's Podfile.lock and Package.resolved beside it.
- `mobile/`: a Flutter app's pubspec.lock, no build (the iOS lockfiles are in `kmm/`).

Each `gradlew` hands its arguments to the Gradle that setup-gradle installs, so
no wrapper jar is committed.
