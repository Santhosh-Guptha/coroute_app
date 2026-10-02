allprojects {
    repositories {
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

// Flutter plugins ship their own compileSdk; a few still declare 34/35 while the AndroidX
// libraries our newer plugins pull in need 36+. Lift every library module to at least 36 so
// the build is reproducible from a clean pub cache (no manual edits in ~/.pub-cache).
subprojects {
    plugins.withId("com.android.library") {
        val androidComponents = extensions.findByType(com.android.build.api.variant.AndroidComponentsExtension::class.java)
        androidComponents?.finalizeDsl { ext ->
            (ext as? com.android.build.api.dsl.LibraryExtension)?.let {
                if ((it.compileSdk ?: 0) < 36) {
                    it.compileSdk = 36
                }
            }
        }
    }
}


tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
