allprojects {
    repositories {
        // Local pre-fetched repo (sandbox build: Java TLS cannot cross the
        // egress proxy, so artifacts are pre-downloaded into ~/local-maven).
        // Missing directory is ignored by Gradle on other machines.
        maven { url = uri("/home/hatch/local-maven") }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
