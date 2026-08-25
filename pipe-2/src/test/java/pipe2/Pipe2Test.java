package pipe2;

import demo.DemoSleep;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertTrue;

class Pipe2Test {
    @Test
    void test1() {
        assertTrue(new Pipe2().name().endsWith("pipe-2"));
        DemoSleep.sleep();
    }
}
