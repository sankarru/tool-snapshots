import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.RoomDatabase

@Entity(tableName = "user")
data class User(
  @PrimaryKey val id: Int,
  val name: String,
)

@Dao
interface UserDao {
  @Query("SELECT * FROM user")
  fun all(): List<User>

  @Insert
  fun insert(u: User)
}

@Database(entities = [User::class], version = 1)
abstract class Db : RoomDatabase() {
  abstract fun dao(): UserDao
}

fun main() {
  println("room ok")
}
