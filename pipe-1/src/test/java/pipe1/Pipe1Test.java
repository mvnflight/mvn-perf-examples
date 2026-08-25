package pipe1;

import demo.DemoSleep;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertTrue;

class Pipe1Test {
    @Test
    void test1() {
        assertTrue(new Pipe1().name().endsWith("pipe-1"));
        DemoSleep.sleep();
    }
}
