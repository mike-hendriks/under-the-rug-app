import Foundation
import simd

/// A lump under the rug, in rug-local points (origin at the rug centre, before rotation).
struct RugBump {
    var id: UUID
    var center: SIMD2<Float>
    var radius: Float
    var height: Float
    /// Animated towards `target`, so lumps grow when something is shoved under and sink when it leaves.
    var scale: Float
    var target: Float
}

@inline(__always) func rotate(_ p: SIMD2<Float>, _ a: Float) -> SIMD2<Float> {
    let c = cos(a), s = sin(a)
    return SIMD2(c * p.x - s * p.y, s * p.x + c * p.y)
}

@inline(__always) func xy(_ v: SIMD3<Float>) -> SIMD2<Float> { SIMD2(v.x, v.y) }

/// Verlet cloth for a heavy wool rug lying on the desktop.
///
/// World space is the view in points: x right, y up, z towards the viewer, the desktop at z = 0.
/// On top of the usual distance constraints the rug keeps a "memory" of its shape through 2D shape
/// matching: every step we fit the best rotation and translation of the goal shape (flat, or folded
/// back) onto the particles and pull them gently towards it. That is what makes a released rug lie
/// flat again instead of staying in a crumpled heap, and it gives us the rug's position and angle.
final class ClothSimulation {
    private struct Constraint {
        var a: Int32
        var b: Int32
        var rest: Float
        var stiffness: Float
    }

    let cols = 43
    let rows = 29
    let width: Float
    let height: Float
    let uvs: [SIMD2<Float>]
    let indices: [UInt16]

    private(set) var positions: [SIMD3<Float>]
    private var previous: [SIMD3<Float>]
    private var inverseMass: [Float]
    /// Per substep: 0 for particles the solver must not move (grabbed, or carried by the fold animation).
    private var solverMass: [Float]
    /// Particles carried by the fold animation this substep.
    private var driven: [Bool]
    private let rest: [SIMD2<Float>]
    private var goal: [SIMD3<Float>]
    private var constraints: [Constraint] = []

    /// Where the rug centre is in world space, and how far it is turned (radians).
    private(set) var center: SIMD2<Float>
    private(set) var angle: Float

    // Folding back one end of the rug.
    private(set) var foldSide = 0
    private(set) var foldDistance: Float = 0
    private var foldTarget: Float = 0
    let foldRadius: Float = 12

    // Grabbing with the mouse.
    private var grabbed: [(index: Int, offset: SIMD2<Float>, lift: Float)] = []
    private var grabTarget = SIMD2<Float>(0, 0)
    private var grabLift: Float = 0

    // Moving the whole rug somewhere (straighten, bring back).
    private var frameTarget: (center: SIMD2<Float>, angle: Float)?

    var bumps: [RugBump] = []
    /// Where a file being dragged over the rug hovers, in rug-local points.
    var hoverPoint: SIMD2<Float>?
    private var hoverBump = RugBump(id: UUID(), center: .zero, radius: 46, height: 7, scale: 0, target: 0)

    private var quietFrames = 0
    private var lastStep: Float = 1.0 / 180
    private(set) var lastMaxMove: Float = 0

    func previousPosition(_ i: Int) -> SIMD3<Float> { previous[i] }
    func goalPosition(_ i: Int) -> SIMD3<Float> { goal[i] }
    func inverseMassOf(_ i: Int) -> Float { inverseMass[i] }
    var isGrabbing: Bool { !grabbed.isEmpty }
    var isFolded: Bool { foldSide != 0 && foldTarget > 0 }
    var isSettled: Bool { quietFrames > 45 }
    var spacing: Float { width / Float(cols - 1) }

    init(width: Float, height: Float, center: SIMD2<Float>, angle: Float, dropHeight: Float) {
        self.width = width
        self.height = height
        self.center = center
        self.angle = angle

        var rest: [SIMD2<Float>] = []
        var uvs: [SIMD2<Float>] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let u = Float(c) / Float(cols - 1)
                let v = Float(r) / Float(rows - 1)
                rest.append(SIMD2(-width / 2 + u * width, -height / 2 + v * height))
                // Texture row 0 is the top of the image, mesh row 0 the bottom of the rug.
                uvs.append(SIMD2(u, 1 - v))
            }
        }
        self.rest = rest
        self.uvs = uvs
        goal = rest.map { SIMD3($0.x, $0.y, 0) }

        // On launch the rug flutters down onto the desktop.
        positions = zip(rest, uvs).map { p, uv in
            let w = rotate(p, angle) + center
            let z = dropHeight > 0 ? dropHeight * (1 + 0.3 * sin(uv.x * .pi * 3 + uv.y * 2)) : 0
            return SIMD3(w.x, w.y, z)
        }
        previous = positions
        inverseMass = Array(repeating: 1, count: rest.count)
        solverMass = inverseMass
        driven = Array(repeating: false, count: rest.count)

        var idx: [UInt16] = []
        for r in 0..<(rows - 1) {
            for c in 0..<(cols - 1) {
                let i0 = UInt16(r * cols + c), i1 = i0 + 1
                let i2 = UInt16((r + 1) * cols + c), i3 = i2 + 1
                if (r + c) % 2 == 0 {
                    idx += [i0, i1, i3, i0, i3, i2]
                } else {
                    idx += [i0, i1, i2, i1, i3, i2]
                }
            }
        }
        indices = idx
        buildConstraints()
    }

    private func buildConstraints() {
        func add(_ c0: Int, _ r0: Int, _ c1: Int, _ r1: Int, _ k: Float) {
            guard c1 < cols, r1 < rows, c1 >= 0 else { return }
            let a = r0 * cols + c0, b = r1 * cols + c1
            constraints.append(Constraint(a: Int32(a), b: Int32(b), rest: simd_distance(rest[a], rest[b]), stiffness: k))
        }
        for r in 0..<rows {
            for c in 0..<cols {
                add(c, r, c + 1, r, 1)         // structure
                add(c, r, c, r + 1, 1)
                add(c, r, c + 1, r + 1, 0.7)   // shear
                add(c + 1, r, c, r + 1, 0.7)
                add(c, r, c + 2, r, 0.3)       // bending: thick wool does not fold easily
                add(c, r, c, r + 2, 0.3)
            }
        }
    }

    // MARK: - Coordinates

    func toLocal(_ w: SIMD2<Float>) -> SIMD2<Float> { rotate(w - center, -angle) }
    func toWorld(_ l: SIMD2<Float>) -> SIMD2<Float> { rotate(l, angle) + center }

    /// Distance from the edge that is being peeled back, along the rug's long axis.
    private func peelDistance(_ local: SIMD2<Float>, side: Int) -> Float {
        side < 0 ? local.x + width / 2 : width / 2 - local.x
    }

    /// True when `local` lies on bare floor because that end of the rug is folded back.
    func isExposed(local: SIMD2<Float>, margin: Float) -> Bool {
        guard foldSide != 0 else { return false }
        return peelDistance(local, side: foldSide) < foldDistance - foldRadius - margin
    }

    /// The floor patch under the rug body (fringe excluded), in world space: bottom-left, bottom-right, top-left, top-right.
    func floorCorners(fringe: Float) -> [SIMD2<Float>] {
        let hx = width / 2 - fringe * width - 2
        let hy = height / 2 - 3
        return [SIMD2(-hx, -hy), SIMD2(hx, -hy), SIMD2(-hx, hy), SIMD2(hx, hy)].map(toWorld)
    }

    // MARK: - Interaction

    /// Picks up the rug near `p` (world). Returns false when `p` is not on the cloth.
    @discardableResult
    func grab(atWorld p: SIMD2<Float>) -> Bool {
        // The topmost particle near the pointer, so a folded flap is grabbed rather than what lies under it.
        var best = -1
        var bestScore = Float.infinity
        let reach = spacing * 1.2
        for i in positions.indices {
            let d = simd_distance(xy(positions[i]), p)
            let score = d - (d < reach ? positions[i].z * 4 : 0)
            if score < bestScore {
                bestScore = score
                best = i
            }
        }
        guard best >= 0, simd_distance(xy(positions[best]), p) < spacing * 2.5 else { return false }

        release()
        let anchor = rest[best]
        for i in positions.indices where simd_distance(rest[i], anchor) <= spacing * 1.6 {
            let isCenter = i == best
            grabbed.append((i, xy(positions[i]) - p, isCenter ? 1 : 0.88))
            inverseMass[i] = 0
        }
        grabTarget = p
        grabLift = max(positions[best].z, 0)
        frameTarget = nil
        quietFrames = 0
        return true
    }

    func drag(toWorld p: SIMD2<Float>) {
        grabTarget = p
        quietFrames = 0
    }

    func release() {
        for g in grabbed { inverseMass[g.index] = 1 }
        grabbed.removeAll()
        quietFrames = 0
    }

    /// Folds the end of the rug nearest to `x` (rug-local) back up to `x`, or lays a folded rug flat again.
    func toggleFold(atLocalX x: Float) {
        if foldSide != 0 {
            foldTarget = 0
        } else {
            let side = x < 0 ? -1 : 1
            fold(side: side, distance: peelDistance(SIMD2(x, 0), side: side))
        }
        quietFrames = 0
    }

    func fold(side: Int, distance: Float) {
        foldSide = side
        foldDistance = 0
        foldTarget = min(max(distance, width * 0.18), width * 0.5)
        quietFrames = 0
    }

    func unfold() {
        if foldSide != 0 { foldTarget = 0 }
        quietFrames = 0
    }

    /// Glides the whole rug to a new place and angle.
    func moveFrame(to center: SIMD2<Float>, angle: Float) {
        frameTarget = (center, angle)
        quietFrames = 0
    }

    /// Puffs the cloth up around `local`, as if something was just shoved underneath.
    func ripple(atLocal local: SIMD2<Float>, strength: Float, radius: Float = 110) {
        for i in positions.indices where inverseMass[i] > 0 {
            let d = simd_distance(toLocal(xy(positions[i])), local)
            guard d < radius else { continue }
            let k = 1 - d / radius
            previous[i].z = positions[i].z - strength * k * k
        }
        quietFrames = 0
    }

    /// A wave along the whole rug, like shaking it out.
    func shake() {
        for i in positions.indices where inverseMass[i] > 0 {
            let u = uvs[i].x
            previous[i].z = positions[i].z - 2.2 * (0.6 + 0.4 * sin(u * .pi * 5))
        }
        quietFrames = 0
    }

    // MARK: - Simulation

    func update(dt: Float) {
        let animating = advanceAnimations(dt)
        let steps = 3
        let h = dt / Float(steps)
        lastStep = h
        for _ in 0..<steps { substep(h) }

        var maxMove: Float = 0
        for i in positions.indices {
            maxMove = max(maxMove, simd_length_squared(positions[i] - previous[i]))
        }
        lastMaxMove = maxMove
        if maxMove < 0.0016 && !animating && !isGrabbing {
            quietFrames += 1
        } else {
            quietFrames = 0
        }
    }

    /// Advances fold, lumps and grab lift. Returns true while any of them still moves.
    private func advanceAnimations(_ dt: Float) -> Bool {
        var animating = false
        if isGrabbing {
            grabLift += (56 - grabLift) * min(1, dt * 12)
        }

        if foldSide != 0 {
            let before = foldDistance
            foldDistance += (foldTarget - foldDistance) * min(1, dt * 3)
            if abs(foldTarget - foldDistance) < 0.3 { foldDistance = foldTarget }
            if foldTarget == 0 && foldDistance < 0.5 {
                foldSide = 0
                foldDistance = 0
            }
            if foldDistance != before || foldSide == 0 {
                recomputeGoal()
                animating = true
            }
        }

        for i in bumps.indices {
            let diff = bumps[i].target - bumps[i].scale
            if abs(diff) < 0.002 {
                bumps[i].scale = bumps[i].target
            } else {
                bumps[i].scale += diff * min(1, dt * 7)
                animating = true
            }
        }
        bumps.removeAll { $0.target == 0 && $0.scale < 0.01 }

        hoverBump.target = hoverPoint == nil ? 0 : 1
        if let p = hoverPoint { hoverBump.center = p }
        let hd = hoverBump.target - hoverBump.scale
        if abs(hd) > 0.002 {
            hoverBump.scale += hd * min(1, dt * 8)
            animating = true
        } else {
            hoverBump.scale = hoverBump.target
        }
        if frameTarget != nil { animating = true }
        return animating
    }

    /// Goal shape in rug-local space: flat, or with one end rolled back over a cylinder like a page curl.
    private func recomputeGoal() {
        let R = foldRadius
        for i in rest.indices {
            let r = rest[i]
            guard foldSide != 0, foldDistance > 0.01 else {
                goal[i] = SIMD3(r.x, r.y, 0)
                continue
            }
            let t = peelDistance(r, side: foldSide)
            if t >= foldDistance {
                goal[i] = SIMD3(r.x, r.y, 0)
                continue
            }
            let a = foldDistance - t
            var T: Float
            var z: Float
            if a <= .pi * R {
                let phi = a / R
                T = foldDistance - R * sin(phi)
                z = R * (1 - cos(phi))
            } else {
                T = foldDistance + (a - .pi * R)
                z = 2 * R
            }
            let x = foldSide < 0 ? T - width / 2 : width / 2 - T
            goal[i] = SIMD3(x, r.y, z)
        }
    }

    private func substep(_ h: Float) {
        let n = positions.count
        let gravity: Float = 2600 * h * h

        // The folded-back flap follows the curl animation directly; the rest of the cloth hangs off it.
        // Letting the solver flip a flap over by itself gets it stuck in twisted local minima.
        for i in 0..<n {
            driven[i] = goal[i].z > 0.5
            solverMass[i] = driven[i] ? 0 : inverseMass[i]
        }

        positions.withUnsafeMutableBufferPointer { p in
            previous.withUnsafeMutableBufferPointer { q in
                solverMass.withUnsafeBufferPointer { w in
                    for i in 0..<n where w[i] > 0 {
                        let v = (p[i] - q[i]) * 0.993
                        q[i] = p[i]
                        p[i] += v
                        p[i].z -= gravity
                    }
                }
            }
        }

        applyGrab(trackVelocity: true)
        solveConstraints(iterations: 14)
        applyGrab(trackVelocity: false)
        // While a fold is held the frame stays put: refitting against a half-folded rug feeds back into the goal and the rug would crawl away.
        if isGrabbing || foldSide == 0 { fitFrame() }
        pullTowardsGoal()
        collideWithFloor()
    }

    private func applyGrab(trackVelocity: Bool) {
        for g in grabbed {
            let t = grabTarget + g.offset
            if trackVelocity { previous[g.index] = positions[g.index] }
            positions[g.index] = SIMD3(t.x, t.y, grabLift * g.lift)
        }
    }

    private func solveConstraints(iterations: Int) {
        positions.withUnsafeMutableBufferPointer { p in
            solverMass.withUnsafeBufferPointer { w in
                driven.withUnsafeBufferPointer { fold in
                constraints.withUnsafeBufferPointer { cs in
                    for _ in 0..<iterations {
                        for c in cs {
                            let a = Int(c.a), b = Int(c.b)
                            // The curl is already in shape; springs across it would only shove the flat part around.
                            if fold[a] || fold[b] { continue }
                            let wa = w[a], wb = w[b]
                            let ws = wa + wb
                            if ws == 0 { continue }
                            let d = p[b] - p[a]
                            let len = simd_length(d)
                            if len < 1e-5 { continue }
                            let corr = d * ((len - c.rest) / (len * ws) * c.stiffness)
                            p[a] += corr * wa
                            p[b] -= corr * wb
                        }
                    }
                }
            }
            }
        }
    }

    /// Best rigid 2D transform from the goal shape onto the particles (shape matching).
    /// Only the part that lies flat counts: a flap that is still travelling while the rug folds
    /// would otherwise drag the frame along with it and the rug would run away.
    private func fitFrame() {
        var n: Float = 0
        var pc = SIMD2<Float>.zero
        var qc = SIMD2<Float>.zero
        for i in positions.indices where goal[i].z < 0.5 {
            pc += xy(positions[i])
            qc += xy(goal[i])
            n += 1
        }
        guard n > 2 else { return }
        pc /= n
        qc /= n
        var A: Float = 0
        var B: Float = 0
        for i in positions.indices where goal[i].z < 0.5 {
            let q = xy(goal[i]) - qc
            let p = xy(positions[i]) - pc
            A += q.x * p.x + q.y * p.y
            B += q.x * p.y - q.y * p.x
        }
        angle = atan2(B, A)
        center = pc - rotate(qc, angle)
    }

    private func pullTowardsGoal() {
        var goalCenter = center
        var goalAngle = angle
        if let target = frameTarget {
            // Walk the goal frame towards the target a little per step, the cloth follows.
            let delta = target.center - center
            let dist = simd_length(delta)
            goalCenter = dist > 2.5 ? center + delta / dist * 2.5 : target.center
            var da = target.angle - angle
            da = atan2(sin(da), cos(da))
            goalAngle = angle + max(-0.01, min(0.01, da))
            if dist < 0.5 && abs(da) < 0.002 { frameTarget = nil }
        }
        let base: Float = isGrabbing ? 0.003 : 0.03
        let c = cos(goalAngle), s = sin(goalAngle)
        positions.withUnsafeMutableBufferPointer { p in
            previous.withUnsafeMutableBufferPointer { q in
                inverseMass.withUnsafeBufferPointer { w in
                    goal.withUnsafeBufferPointer { g in
                        for i in 0..<p.count where w[i] > 0 {
                            let gl = g[i]
                            let gx = c * gl.x - s * gl.y + goalCenter.x
                            let gy = s * gl.x + c * gl.y + goalCenter.y
                            if gl.z > 0.5 {
                                // Fold-driven: rides the curl exactly, no momentum of its own.
                                p[i] = SIMD3(gx, gy, gl.z)
                                q[i] = p[i]
                                continue
                            }
                            let d = SIMD3(gx - p[i].x, gy - p[i].y, 0) * base
                            p[i] += d
                            // Move most of the history along too, so the pull reshapes without adding much bounce.
                            q[i] += d * 0.7
                        }
                    }
                }
            }
        }
    }

    private func collideWithFloor() {
        var active = bumps.filter { $0.scale > 0.01 }
        if hoverBump.scale > 0.01 { active.append(hoverBump) }
        let c = cos(-angle), s = sin(-angle)
        let center = self.center
        let friction: Float = 0.14

        positions.withUnsafeMutableBufferPointer { p in
            previous.withUnsafeMutableBufferPointer { q in
                solverMass.withUnsafeBufferPointer { w in
                    for i in 0..<p.count where w[i] > 0 {
                        var floor: Float = 0
                        if !active.isEmpty {
                            let rx = p[i].x - center.x, ry = p[i].y - center.y
                            let local = SIMD2(c * rx - s * ry, s * rx + c * ry)
                            for b in active {
                                let d2 = simd_distance_squared(local, b.center)
                                let r2 = b.radius * b.radius
                                if d2 < r2 {
                                    let t = 1 - d2 / r2
                                    floor = max(floor, b.height * b.scale * t * t)
                                }
                            }
                        }
                        if p[i].z < floor {
                            p[i].z = floor
                            // No bounce, and a rising lump must not launch the cloth.
                            q[i].z = p[i].z
                            let vx = p[i].x - q[i].x, vy = p[i].y - q[i].y
                            q[i].x = p[i].x - vx * (1 - friction)
                            q[i].y = p[i].y - vy * (1 - friction)
                        }
                    }
                }
            }
        }
    }
}

extension ClothSimulation {
    /// Debug helper: the particle that moved most in the last substep.
    func debugWorstParticle() -> String {
        var worst = 0
        var best: Float = -1
        for i in positions.indices {
            let m = simd_length(positions[i] - previousPosition(i))
            if m > best { best = m; worst = i }
        }
        return "worst \(worst) col \(worst % cols) row \(worst / cols) move \(best) pos \(positions[worst]) goal \(goalPosition(worst)) mass \(inverseMassOf(worst))"
    }
}
