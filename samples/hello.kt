fun main(args: Array<String>) {
  println("hello from ${args.firstOrNull() ?: "snapshot"}")
}
