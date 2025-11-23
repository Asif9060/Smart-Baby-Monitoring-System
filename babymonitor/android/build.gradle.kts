allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Use the legacy buildDir property to avoid issues with spaces in paths
// when using layout.buildDirectory with relative paths.
val newBuildDir = java.io.File(rootDir.parentFile, "build")
rootProject.buildDir = newBuildDir

subprojects {
    project.buildDir = java.io.File(newBuildDir, project.name)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.buildDir)
}
