package lib01;

import demo.DemoSleep;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertTrue;

class Lib01Test {
    @Test
    void test1() {
        assertTrue(new Lib01().name().endsWith("lib-01"));
        DemoSleep.sleep();
    }
}
