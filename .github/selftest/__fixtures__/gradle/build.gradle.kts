plugins {
    `java-library`
    id("org.cyclonedx.bom") version "3.5.1"
}

repositories { mavenCentral() }

dependencies {
    implementation("org.slf4j:slf4j-api:2.0.17")
}
