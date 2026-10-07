import Foundation

/// Minimum-cost assignment (Kuhn–Munkres, O(n³)) on a rectangular cost matrix.
///
/// Used to match remote voices to names: each voice gets at most one name, each name at
/// most one voice, and the total cost is minimal — unlike greedy "best match first", which
/// can hand the second voice a poor name because the first took its good one.
public enum Hungarian {
    /// - Parameter cost: `rows × columns`, every row the same length. Finite values only.
    /// - Returns: for each row, the assigned column, or `nil` when there are more rows than
    ///   columns and the row was left out.
    public static func assign(_ cost: [[Double]]) -> [Int?] {
        let rows = cost.count
        guard rows > 0, let columns = cost.first?.count, columns > 0 else {
            return Array(repeating: nil, count: rows)
        }
        let n = max(rows, columns)
        let pad = (cost.joined().map(abs).max() ?? 0) + 1

        // 1-indexed square matrix; padded cells cost the same, so they never bias a choice.
        var a = Array(repeating: Array(repeating: pad, count: n + 1), count: n + 1)
        for i in 0..<rows {
            for j in 0..<columns {
                a[i + 1][j + 1] = cost[i][j]
            }
        }

        var u = Array(repeating: 0.0, count: n + 1)
        var v = Array(repeating: 0.0, count: n + 1)
        var p = Array(repeating: 0, count: n + 1)  // p[j] = row matched to column j
        var way = Array(repeating: 0, count: n + 1)

        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minv = Array(repeating: Double.infinity, count: n + 1)
            var used = Array(repeating: false, count: n + 1)
            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = Double.infinity
                var j1 = 0
                for j in 1...n where !used[j] {
                    let current = a[i0][j] - u[i0] - v[j]
                    if current < minv[j] {
                        minv[j] = current
                        way[j] = j0
                    }
                    if minv[j] < delta {
                        delta = minv[j]
                        j1 = j
                    }
                }
                for j in 0...n {
                    if used[j] {
                        u[p[j]] += delta
                        v[j] -= delta
                    } else {
                        minv[j] -= delta
                    }
                }
                j0 = j1
            } while p[j0] != 0
            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }

        var result: [Int?] = Array(repeating: nil, count: rows)
        for j in 1...n where p[j] >= 1 && p[j] <= rows && j <= columns {
            result[p[j] - 1] = j - 1
        }
        return result
    }
}
