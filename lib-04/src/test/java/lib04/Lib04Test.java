package lib04;

import demo.DemoSleep;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertTrue;

class Lib04Test {
    @Test
    void test1() {
        assertTrue(new Lib04().name().endsWith("lib-04"));
        DemoSleep.sleep();
    }
}
