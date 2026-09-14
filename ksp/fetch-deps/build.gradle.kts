// KSP2 + Room fetch project. Resolution only (no plugins), so no build
// tools run here. Pinned versions are the single source of truth for the
// Room/KSP trace + smoke in scripts/snapshot.sh.
import org.gradle.api.attributes.Category
import org.gradle.api.attributes.Usage
import org.gradle.api.attributes.java.TargetJvmEnvironment

val kspVersion = "2.2.20-2.0.4"
val roomVersion = "2.8.5"

configurations {
    // KSP2 standalone runner (AA uber jar + common deps + api).
    create("kspAA")
    // Room annotation processor + its closure (apclasspath).
    create("kspProc")
    // Room compile classpath (runtime + sqlite + annotation).
    create("kspCompile")
    // The processor runs on the JVM: pin standard-jvm (this is what picks
    // guava's jre flavor over its android flavor).
    listOf("kspAA", "kspProc").forEach { name ->
        named(name) {
            attributes {
                attribute(Category.CATEGORY_ATTRIBUTE, objects.named(Category.LIBRARY))
                attribute(Usage.USAGE_ATTRIBUTE, objects.named(Usage.JAVA_RUNTIME))
                attribute(
                    TargetJvmEnvironment.TARGET_JVM_ENVIRONMENT_ATTRIBUTE,
                    objects.named(TargetJvmEnvironment.STANDARD_JVM)
                )
            }
        }
    }
    // The compile classpath mixes JVM jars and Android AARs
    // (room-runtime-android declares jvm.environment=android), so NO
    // jvm.environment request here -- artifacts without it match by wildcard.
    named("kspCompile") {
        attributes {
            attribute(Category.CATEGORY_ATTRIBUTE, objects.named(Category.LIBRARY))
            attribute(Usage.USAGE_ATTRIBUTE, objects.named(Usage.JAVA_RUNTIME))
        }
    }
}

dependencies {
    add("kspAA", "com.google.devtools.ksp:symbol-processing-aa:$kspVersion")
    add("kspAA", "com.google.devtools.ksp:symbol-processing-common-deps:$kspVersion")
    add("kspAA", "com.google.devtools.ksp:symbol-processing-api:2.0.10-1.0.24")
    add("kspProc", "androidx.room:room-compiler:$roomVersion")
    // Full Android impl as the single room-runtime source: performBlocking
    // and friends live here in the KMP layout. Do NOT also depend on the
    // base room-runtime (resolves to -jvm) -- the two androidx.room.util
    // facades collide on one kotlinc classpath and performBlocking vanishes.
    add("kspCompile", "androidx.room:room-runtime-android:$roomVersion")
    add("kspCompile", "androidx.sqlite:sqlite:2.5.0")
    add("kspCompile", "androidx.annotation:annotation:1.8.1")
}

tasks.register("fetchAA", Copy::class) {
    from(configurations["kspAA"])
    into(layout.buildDirectory.dir("aa"))
}
tasks.register("fetchProc", Copy::class) {
    from(configurations["kspProc"])
    into(layout.buildDirectory.dir("proc"))
}
tasks.register("fetchCompile", Copy::class) {
    from(configurations["kspCompile"])
    into(layout.buildDirectory.dir("compile"))
}
