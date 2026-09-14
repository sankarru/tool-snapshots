@Deprecated("use new() instead")
fun old() = 1

fun new() = 2

fun main() {
  val unused = 1
  println(old() + new() + unused - unused)
}
