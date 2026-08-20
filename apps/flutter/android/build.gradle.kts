allprojects {
    repositories {
        // Prefer the mirrors: a TLS handshake failure against Maven Central
        // otherwise prevents Gradle from trying the fallback repository.
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
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
// These older plugins use different Java targets. Match Kotlin to each
// plugin's Java task so Gradle accepts release builds on all runners.
subprojects {
    if (name == "receive_sharing_intent") {
        afterEvaluate {
            tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
                compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
    }
    if (name == "flutter_foreground_task") {
        afterEvaluate {
            tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
                compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
            }
        }
    }
}

// Keep Android library plugins on the stable SDK installed by release CI.
subprojects {
    if (name != "app") {
        afterEvaluate {
            extensions.findByName("android")?.let { ext ->
                if (ext is com.android.build.gradle.LibraryExtension) {
                    ext.compileSdk = 36
                }
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
