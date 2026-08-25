package pipe3;

import demo.DemoSleep;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertTrue;

class Pipe3Test {
    @Test
    void test1() {
        assertTrue(new Pipe3().name().endsWith("pipe-3"));
        DemoSleep.sleep();
    }
}
