plugins {
    alias(libs.plugins.android.application)
}

abstract class GeneratePackageLogoResources : org.gradle.api.DefaultTask() {
    @get:org.gradle.api.tasks.InputDirectory
    @get:org.gradle.api.tasks.PathSensitive(org.gradle.api.tasks.PathSensitivity.RELATIVE)
    abstract val resourceDirectory: org.gradle.api.file.DirectoryProperty

    @get:org.gradle.api.tasks.OutputDirectory
    abstract val outputDirectory: org.gradle.api.file.DirectoryProperty

    @org.gradle.api.tasks.TaskAction
    fun generate() {
        val sourceResources = resourceDirectory.get().asFile
        val generatedResources = outputDirectory.get().asFile
        generatedResources.deleteRecursively()

        sourceResources.walkTopDown()
            .filter { it.isFile }
            .forEach { source ->
                val destination = generatedResources.resolve(source.relativeTo(sourceResources).path)
                destination.parentFile.mkdirs()
                source.copyTo(destination, overwrite = true)
            }

        val logoFile = sourceResources.resolve("drawable/logo.png")
        if (!logoFile.isFile) {
            logger.lifecycle("drawable/logo.png was not found; using the default launcher icon.")
            return
        }

        listOf("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi").forEach { density ->
            val densityDirectory = generatedResources.resolve("mipmap-$density")
            logoFile.copyTo(densityDirectory.resolve("ic_launcher_logo.png"), overwrite = true)
        }

        val foregroundDirectory = generatedResources.resolve("drawable-nodpi")
        foregroundDirectory.mkdirs()
        logoFile.copyTo(
            foregroundDirectory.resolve("ic_launcher_package_foreground.png"),
            overwrite = true
        )
        generatedResources.resolve("mipmap-anydpi-v26/ic_launcher_logo.xml").writeText(
            """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_package_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
""",
            Charsets.UTF_8
        )
        logger.lifecycle("Using drawable/logo.png as the launcher logo.")
    }
}

android {
    namespace = "com.ijtc.allapp"

    compileSdk {
        version = release(37)
    }

    defaultConfig {
        applicationId = "com.ijtc.tqimapk"
        minSdk = 24
        targetSdk = 37
        versionCode = 1
        versionName = "1.1"

    }

    buildTypes {
        release {
            proguardFiles("proguard-rules.pro")
            optimization {
                enable = true
                packageScope = setOf("androidx.**", "kotlin.**", "kotlinx.**")
            }
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
}

val mainResourceDirectory = layout.projectDirectory.dir("src/main/res")
android.sourceSets.getByName("main").res.directories.clear()

androidComponents {
    onVariants { variant ->
        val variantTaskName = "generate${variant.name.replaceFirstChar { it.uppercase() }}PackageLogoResources"
        val generateResources = tasks.register(
            variantTaskName,
            GeneratePackageLogoResources::class.java
        ) {
            resourceDirectory.set(mainResourceDirectory)
            outputDirectory.set(
                layout.buildDirectory.dir("generated/res/packageLogo/${variant.name}")
            )
        }
        variant.sources.res?.addGeneratedSourceDirectory(
            generateResources,
            GeneratePackageLogoResources::outputDirectory
        )
    }
}

dependencies {
    testImplementation(libs.junit)
}

val testDebugUnitTestTasks = tasks.matching { it.name == "testDebugUnitTest" }
val skipInstallAndRun = providers.gradleProperty("skipInstallAndRun")
    .map(String::toBoolean)
    .getOrElse(false)
val installAndRunDebugTask = tasks.register<Exec>("installAndRunDebug") {
    dependsOn("assembleDebug")
    enabled = !skipInstallAndRun
    workingDir(rootProject.projectDir)
    commandLine(
        "cmd.exe",
        "/c",
        "call",
        "\"${rootProject.file("Install-Debug-Run.bat").absolutePath}\""
    )
}

tasks.configureEach {
    if (name == "assembleDebug") {
        dependsOn(testDebugUnitTestTasks)
        finalizedBy(installAndRunDebugTask)
    }
}