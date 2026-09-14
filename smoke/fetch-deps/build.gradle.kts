// Dependency-fetch ONLY project. Deliberately no Android/Kotlin plugins:
// resolving artifacts must never invoke AAPT2, R8 or D8. The smoke test
// compiles with kotlinc directly and dexes/shrinks with the AOT snapshots.
val composeBom = "androidx.compose:compose-bom:2025.01.00"

configurations {
    create("fetch")
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
