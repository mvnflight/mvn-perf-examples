package pipe4;

import demo.DemoSleep;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertTrue;

class Pipe4Test {
    @Test
    void test1() {
        assertTrue(new Pipe4().name().endsWith("pipe-4"));
        DemoSleep.sleep();
    }
}
