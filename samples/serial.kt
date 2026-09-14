import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
data class Fact(val title: String, val level: Int = 0)

fun main() {
  println(Json.encodeToString(Fact("aot", 1)))
}
