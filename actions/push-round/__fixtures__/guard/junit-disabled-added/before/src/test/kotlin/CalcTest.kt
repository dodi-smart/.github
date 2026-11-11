package calc

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class CalcTest {
    @Test
    fun doubles() {
        assertEquals(4, double(2))
    }
}
