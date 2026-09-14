open class BaseService {
  open fun start() = "started"
}

class MyService : BaseService()

fun main() {
  println(MyService().start())
}
