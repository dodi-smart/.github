package calc

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Disabled
import org.junit.jupiter.api.Test

class CalcTest {
    @Disabled
    @Test
    fun doubles() {
        assertEquals(4, double(2))
    }
}
