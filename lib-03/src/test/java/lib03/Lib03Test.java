package lib03;

import demo.DemoSleep;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertTrue;

class Lib03Test {
    @Test
    void test1() {
        assertTrue(new Lib03().name().endsWith("lib-03"));
        DemoSleep.sleep();
    }
}
