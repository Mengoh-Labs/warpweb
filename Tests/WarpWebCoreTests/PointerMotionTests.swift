import Testing
@testable import WarpWebCore

@Test func multiClickTimingAndDragReset() {
    var clicks = PointerClicks()
    #expect(clicks.press(x:10,y:10,right:false,time:1,interval:0.5) == 1)
    #expect(clicks.press(x:12,y:10,right:false,time:1.2,interval:0.5) == 2)
    #expect(clicks.press(x:12,y:10,right:false,time:1.4,interval:0.5) == 3)
    #expect(clicks.press(x:12,y:10,right:false,time:2,interval:0.5) == 1)
    #expect(clicks.press(x:12,y:10,right:true,time:2.1,interval:0.5) == 1)
    clicks.drag(x:30,y:10)
    #expect(clicks.press(x:12,y:10,right:true,time:2.2,interval:0.5) == 1)
    #expect(clicks.press(x:50,y:10,right:true,time:2.3,interval:0.5) == 1)
}

@Test func scrollingIsIncrementalExactAndBounded() {
    var motion = ScrollMotion()
    motion.add(40)
    let first = motion.step(seconds:1.0/60)
    #expect(first > 0 && first < 40)
    var total = first
    for _ in 0..<60 { total += motion.step(seconds:1.0/60) }
    #expect(total == 40 && motion.remaining == 0)
    motion.add(4000)
    #expect(motion.remaining == 800)
    motion.add(-40)
    #expect(motion.remaining == -40)
    total = 0
    for _ in 0..<60 { total += motion.step(seconds:1.0/60) }
    #expect(total == -40)
}

@Test func scrollClockIsIndependentOfCaptureFrequency() {
    var regular = ScrollMotion(), frequent = ScrollMotion()
    regular.add(400); frequent.add(400)
    let one = regular.step(seconds:1.0/60)
    var many = 0
    for _ in 0..<20 { many += frequent.step(seconds:1.0/1200) }
    #expect(one == many)
    #expect(regular.remaining == frequent.remaining)
    #expect(frequent.step(seconds:0) == 0)
    #expect(frequent.step(seconds:-1) == 0)
    frequent.add(-40)
    #expect(frequent.step(seconds:1.0/60) < 0)
}
