plugins {
    alias(libs.plugins.android.application)
}

abstract class GeneratePackageLogoResources : org.gradle.api.DefaultTask() {
    @get:org.gradle.api.tasks.InputDirectory
    @get:org.gradle.api.tasks.PathSensitive(org.gradle.api.tasks.PathSensitivity.RELATIVE)
    abstract val resourceDirectory: org.gradle.api.file.DirectoryProperty

    @get:org.gradle.api.tasks.OutputDirectory
    abstract val outputDirectory: org.gradle.api.file.DirectoryProperty

    @get:org.gradle.api.tasks.Input
    abstract val applicationId: org.gradle.api.provider.Property<String>

    @org.gradle.api.tasks.TaskAction
    fun generate() {
        val sourceResources = resourceDirectory.get().asFile
        val generatedResources = outputDirectory.get().asFile
        generatedResources.deleteRecursively()

        sourceResources.walkTopDown()
            .filter { it.isFile }
            .filterNot {
                it.parentFile.name.startsWith("mipmap-") && it.name == "ic_launcher_logo.png"
            }
            .forEach { source ->
                val destination = generatedResources.resolve(source.relativeTo(sourceResources).path)
                destination.parentFile.mkdirs()
                source.copyTo(destination, overwrite = true)
            }

        val packageSuffix = applicationId.get().substringAfterLast('.')
        val fixedLogoFile = sourceResources.resolve("drawable/logo.png")
        val logoFile = if (fixedLogoFile.isFile) {
            fixedLogoFile
        } else {
            if (!packageSuffix.matches(Regex("[a-z][a-z0-9_]*"))) {
                throw org.gradle.api.GradleException(
                    "The last applicationId segment '$packageSuffix' must be a lowercase Android resource name."
                )
            }
            sourceResources.resolve("drawable/$packageSuffix.png")
        }
        if (!logoFile.isFile) {
            throw org.gradle.api.GradleException(
                "Logo not found: app/src/main/res/drawable/logo.png or " +
                    "app/src/main/res/drawable/$packageSuffix.png."
            )
        }
        val logoResourceName = logoFile.nameWithoutExtension

        fun writePaddedDrawable(destination: java.io.File, drawable: String) {
            destination.parentFile.mkdirs()
            destination.writeText(
                """<?xml version="1.0" encoding="utf-8"?>
<inset xmlns:android="http://schemas.android.com/apk/res/android"
    android:drawable="$drawable"
    android:insetLeft="20dp"
    android:insetTop="20dp"
    android:insetRight="20dp"
    android:insetBottom="20dp" />
""",
                Charsets.UTF_8
            )
        }

        listOf("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi").forEach { density ->
            val densityDirectory = generatedResources.resolve("mipmap-$density")
            writePaddedDrawable(
                densityDirectory.resolve("ic_launcher_logo.xml"),
                "@drawable/$logoResourceName"
            )
        }

        val foregroundDirectory = generatedResources.resolve("drawable-nodpi")
        foregroundDirectory.mkdirs()
        writePaddedDrawable(
            foregroundDirectory.resolve("ic_launcher_package_foreground.xml"),
            "@drawable/$logoResourceName"
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
        logger.lifecycle(
            "Using drawable/$logoResourceName.png as the launcher and Recent Apps logo with 20dp padding."
        )
    }
}

android {
    namespace = "com.ijtc.allapp"

    compileSdk {
        version = release(37)
    }

    defaultConfig {
        applicationId = "com.ijtc.rre"
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
            applicationId.set(variant.applicationId)
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