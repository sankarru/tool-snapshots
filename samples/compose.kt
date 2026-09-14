import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue

@Composable
fun Counter(): Int {
  var n by remember { mutableStateOf(0) }
  n++
  return n
}

fun main() {
  println("compose ok")
}
