package lib02;

import demo.DemoSleep;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertTrue;

class Lib02Test {
    @Test
    void test1() {
        assertTrue(new Lib02().name().endsWith("lib-02"));
        DemoSleep.sleep();
    }
}
