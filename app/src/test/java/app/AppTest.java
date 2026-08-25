package app;

import demo.DemoSleep;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

class AppTest {
    @Test
    void countsAllModules() {
        assertEquals(10, new App().moduleCount());
        DemoSleep.sleep();
    }
}
