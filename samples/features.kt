import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking

sealed interface Shape {
  data class Circle(val r: Double) : Shape
  data object Dot : Shape
}

enum class Level { LOW, HIGH }

data class Box<T>(val items: List<T>)

object Registry {
  private val map = mutableMapOf<String, Any>()
  operator fun set(k: String, v: Any) { map[k] = v }
  operator fun get(k: String) = map[k]
}

class LazyInit {
  val heavy by lazy { (1..100).sum() }
}

fun describe(s: Shape) = when (s) {
  is Shape.Circle -> "c${s.r}"
  Shape.Dot -> "dot"
}

fun <T> firstOr(data: Box<T>, d: T) = data.items.firstOrNull() ?: d

suspend fun fetch(n: Int): Int = n * 2

fun main() = runBlocking {
  Registry["a"] = 1
  val deferred = async { fetch(21) }
  println(describe(Shape.Circle(1.0)) + firstOr(Box(listOf(1)), 0) + deferred.await() + Level.HIGH)
}
