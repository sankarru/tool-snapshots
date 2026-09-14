import kotlin.reflect.full.memberProperties
import kotlin.reflect.full.primaryConstructor

data class Person(val name: String, val age: Int = 0)

fun main() {
  val k = Person::class
  println(k.memberProperties.map { it.name })
  println(k.primaryConstructor!!.call("Ann", 3))
}
