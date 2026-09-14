// Dependency-fetch ONLY project. Deliberately no Android/Kotlin plugins:
// resolving artifacts must never invoke AAPT2, R8 or D8. The smoke test
// compiles with kotlinc directly and dexes/shrinks with the AOT snapshots.
import org.gradle.api.attributes.Attribute
import org.gradle.api.attributes.AttributeCompatibilityRule
import org.gradle.api.attributes.Category
import org.gradle.api.attributes.CompatibilityCheckDetails
import org.gradle.api.attributes.Usage

val composeBom = "androidx.compose:compose-bom:2025.01.00"

// Mirror of the Kotlin Gradle plugin's rule: a producer built for plain
// jvm is usable where androidJvm was requested (exact androidJvm matches
// still rank higher, so android variants win ties).
abstract class AndroidJvmCompat : AttributeCompatibilityRule<String> {
    override fun execute(details: CompatibilityCheckDetails<String>) {
        if (details.consumerValue == "androidJvm" && details.producerValue == "jvm") {
            details.compatible()
        }
    }
}

dependencies {
    attributesSchema {
        attribute(Attribute.of("org.jetbrains.kotlin.platform.type", String::class.java)) {
            compatibilityRules.add(AndroidJvmCompat::class)
        }
    }
}

configurations {
    create("fetch") {
        // Variant-aware matching without the Android plugin: these three
        // attributes pick the android artifacts out of multiplatform modules
        // (e.g. skiko's androidRuntimeElements vs awtRuntimeElements -- the
        // only difference is ui=android, and Gradle prefers the variant with
        // the most matching attributes). Artifacts that don't declare `ui`
        // are unaffected. libraryelements is deliberately NOT requested so
        // AAR variants stay eligible (the smoke script explodes them).
        attributes {
            attribute(Category.CATEGORY_ATTRIBUTE, objects.named(Category.LIBRARY))
            attribute(Usage.USAGE_ATTRIBUTE, objects.named(Usage.JAVA_RUNTIME))
            attribute(Attribute.of("ui", String::class.java), "android")
            // androidx.compose artifacts ship android and desktop variants;
            // without this the graph drifts to ui-desktop -> skiko-android
            // (a module that does not exist). Pure-JVM artifacts ignore it.
            attribute(
                Attribute.of("org.jetbrains.kotlin.platform.type", String::class.java),
                "androidJvm"
            )
        }
    }
}

dependencies {
    add("fetch", platform(composeBom))
    add("fetch", "androidx.compose.ui:ui")
    add("fetch", "androidx.compose.ui:ui-graphics")
    add("fetch", "androidx.compose.ui:ui-tooling-preview")
    add("fetch", "androidx.compose.material3:material3:1.3.1")
    add("fetch", "androidx.activity:activity-compose:1.10.0")
    add("fetch", "androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    add("fetch", "org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    add("fetch", "org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    add("fetch", "androidx.profileinstaller:profileinstaller:1.4.1")
}

tasks.register("fetch", Copy::class) {
    from(configurations["fetch"])
    into(layout.buildDirectory.dir("libs"))
}
