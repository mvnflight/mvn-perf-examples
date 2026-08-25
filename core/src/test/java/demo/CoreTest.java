package demo;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

class CoreTest {
    @Test
    void describes() {
        assertEquals("core", new Core().name());
        DemoSleep.sleep();
    }
}
