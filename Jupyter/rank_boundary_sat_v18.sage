#!/usr/bin/env sage
# -*- coding: utf-8 -*-
"""rank_boundary_sat_v13.sage

Feasibility for low mod-2 boundary rank via Boolean polynomial constraints.

Problem (over GF(2)):
  Given an adjacency matrix A (N x N) with zero diagonal, decide whether there exists
  a permutation matrix P such that

      rank_{GF(2)}( B(P) ) <= r,

  where B(P) := ∂(P A P^T) is the mod-2 adjacency boundary:

      ∂T = Σ_{k=0}^{N-1} d_k(T)  in M_{N-1}(GF(2)),

  with d_k deleting row/column k (canonical relabeling).

Determinantal encoding (Groebner/SAT-friendly):
  dim(B) = (N-1). If rank(B) <= r then dim ker(B) >= kdim := (N-1)-r.
  Introduce Y ∈ GF(2)^{(N-1)×kdim} and impose

      B(P) * Y = 0,

  plus a gauge fixing Y_J = I_{kdim} for some row subset J of size kdim.
  For fixed J this avoids enumerating minors of B.

Solvers:
  --solver groebner : Boolean Groebner basis (PolyBoRi). May hit size limits.
  --solver sat      : ANF→SAT via sage.sat.boolean_polynomials.solve with
                      --sat_backend {auto, cryptominisat, picosat, lp}.

Important backend notes:
  * cryptominisat needs pycryptosat (often ABI-broken in custom builds).
  * picosat needs pycosat.
  * lp (SatLP) is a robust fallback but slower; in Sage 10.5 SatLP.var()
    does NOT accept decision=..., so we wrap it.

This file supersedes earlier rank_boundary_sat*.sage variants.
"""

from sage.all import *
import argparse
import itertools
import random
import os
import sys, time, threading
from datetime import datetime


# ------------------------------------------------------------
# Graph adjacencies as GF(2) matrices (explicit for N=16)
# ------------------------------------------------------------

def rook_adj_4x4_GF2():
    # vertices (r,c), idx = 4*r + c
    F = GF(2)
    N = 16
    A = zero_matrix(F, N, N)
    for r in range(4):
        for c in range(4):
            u = 4*r + c
            # same row
            for c2 in range(4):
                if c2 != c:
                    v = 4*r + c2
                    A[u, v] = 1
            # same col
            for r2 in range(4):
                if r2 != r:
                    v = 4*r2 + c
                    A[u, v] = 1
    for u in range(N):
        A[u, u] = 0
    return A


def shrikhande_adj_GF2():
    # Cayley graph on Z4×Z4 with generators:
    diffs = [(1, 0), (3, 0), (0, 1), (0, 3), (1, 1), (3, 3)]
    F = GF(2)
    N = 16
    A = zero_matrix(F, N, N)

    def idx(i, j):
        return 4*i + j

    for i in range(4):
        for j in range(4):
            u = idx(i, j)
            for di, dj in diffs:
                v = idx((i + di) % 4, (j + dj) % 4)
                A[u, v] = 1
                A[v, u] = 1
    for u in range(N):
        A[u, u] = 0
    return A


def petersen_adj_GF2():
    # Use Sage's built-in PetersenGraph
    F = GF(2)
    P = graphs.PetersenGraph()
    # relabel to 0..9 in a deterministic order
    P = P.relabel({v: i for i, v in enumerate(sorted(P.vertices()))}, inplace=False)
    A = matrix(F, P.adjacency_matrix())
    for i in range(A.nrows()):
        A[i, i] = 0
    return A


def load_graph_GF2(spec: str):
    if spec == "rook":
        return rook_adj_4x4_GF2()
    if spec == "shrikhande":
        return shrikhande_adj_GF2()
    if spec == "petersen":
        return petersen_adj_GF2()
    if spec.startswith("atlas:"):
        idx = int(spec.split(":")[1])
        G = graphs.GraphAtlas(idx)
        G = G.relabel({v: i for i, v in enumerate(sorted(G.vertices()))}, inplace=False)
        A = matrix(GF(2), G.adjacency_matrix())
        for i in range(A.nrows()):
            A[i, i] = 0
        return A
    raise ValueError(f"Unknown graph spec: {spec}")


# ------------------------------------------------------------
# Boundary (for verification / witness check)
# ------------------------------------------------------------

def boundary_mod2_matrix(T):
    # T is NxN over GF(2), return (N-1)x(N-1)
    F = GF(2)
    N = T.nrows()
    dim = N - 1
    B = zero_matrix(F, dim, dim)
    for k in range(N):
        rows = [i for i in range(N) if i != k]
        face = T.matrix_from_rows_and_columns(rows, rows)
        B += face
    return B


def boundary_rank_of_perm(A0, perm):
    Ap = A0.matrix_from_rows_and_columns(perm, perm)
    B = boundary_mod2_matrix(Ap)
    return B.rank(), B


# ------------------------------------------------------------
# Boolean polynomial system
# ------------------------------------------------------------

def make_variable_ring(N, r):
    """Variables:
        x_{i,v} : permutation matrix entries (N x N)
        b_{u,v} : boundary entries ((N-1) x (N-1))
        y_{v,t} : kernel basis ((N-1) x kdim), kdim = (N-1)-r
    """
    dim = N - 1
    kdim = dim - r
    if kdim <= 0:
        raise ValueError("Need r <= N-2 so that kdim >= 1")

    names = []
    for i in range(N):
        for v in range(N):
            names.append(f"x_{i}_{v}")
    for u in range(dim):
        for v in range(dim):
            names.append(f"b_{u}_{v}")
    for v in range(dim):
        for t in range(kdim):
            names.append(f"y_{v}_{t}")

    R = BooleanPolynomialRing(len(names), names)
    V = R.gens_dict()

    def x(i, v):
        return V[f"x_{i}_{v}"]

    def b(u, v):
        return V[f"b_{u}_{v}"]

    def y(v, t):
        return V[f"y_{v}_{t}"]

    return R, x, b, y, dim, kdim


def permutation_constraints(N, x):
    """Permutation matrix constraints over GF(2):

    Row i: sum_v x_{i,v} = 1 and pairwise products x_{i,u}x_{i,v}=0.
    Col v: sum_i x_{i,v} = 1 and pairwise products x_{i,v}x_{j,v}=0.
    """
    eqs = []

    # row sums
    for i in range(N):
        s = 0
        for v in range(N):
            s += x(i, v)
        eqs.append(s + 1)

    # row exclusivity
    for i in range(N):
        for u in range(N):
            for v in range(u + 1, N):
                eqs.append(x(i, u) * x(i, v))

    # col sums
    for v in range(N):
        s = 0
        for i in range(N):
            s += x(i, v)
        eqs.append(s + 1)

    # col exclusivity
    for v in range(N):
        for i in range(N):
            for j in range(i + 1, N):
                eqs.append(x(i, v) * x(j, v))

    return eqs


def build_Ap_polys(A0, x, R):
    """Ap_{i,j} = (P A0 P^T)_{i,j} = Σ_{u,v} A0_{u,v} x_{i,u} x_{j,v}."""
    N = A0.nrows()
    ones = [(u, v) for u in range(N) for v in range(N) if A0[u, v] == 1]
    Ap = [[R(0) for _ in range(N)] for __ in range(N)]
    for i in range(N):
        for j in range(N):
            s = R(0)
            for (u, v) in ones:
                s += x(i, u) * x(j, v)
            Ap[i][j] = s
    return Ap


def boundary_entry_constraints_from_Ap_fast(N, dim, Ap, b, R):
    """Fast parity formula for the boundary entries.

    For u<v in [0..dim-1], with dim=N-1,
      B[u,v] = (u+1 mod2)*Ap[u+1,v+1] + ((v-u) mod2)*Ap[u,v+1] + ((N-1-v) mod2)*Ap[u,v].

    Since A is symmetric with zero diagonal, Ap and B are symmetric, and B[u,u]=0.
    We enforce b(u,v)=that expression for all u,v by using (uu=min, vv=max).
    """
    eqs = []
    for u in range(dim):
        for v in range(dim):
            if u == v:
                eqs.append(b(u, v))
                continue
            uu = u if u < v else v
            vv = v if u < v else u
            s = R(0)
            if ((uu + 1) & 1):
                s += Ap[uu + 1][vv + 1]
            if (((vv - uu) & 1)):
                s += Ap[uu][vv + 1]
            if (((N - 1 - vv) & 1)):
                s += Ap[uu][vv]
            eqs.append(b(u, v) + s)
    return eqs


def kernel_constraints(dim, kdim, b, y):
    """B*Y = 0."""
    eqs = []
    for u in range(dim):
        for t in range(kdim):
            s = 0
            for v in range(dim):
                s += b(u, v) * y(v, t)
            eqs.append(s)
    return eqs


def gauge_constraints(J, kdim, y):
    """Gauge-fix Y_J = I_{kdim}.

    J is an ordered list of kdim distinct row indices.
    """
    if len(J) != kdim:
        raise ValueError("J must have size kdim")
    if len(set(J)) != kdim:
        raise ValueError("J must have distinct entries")
    eqs = []
    for t in range(kdim):
        eqs.append(y(J[t], t) + 1)
        for s in range(kdim):
            if s != t:
                eqs.append(y(J[s], t))
    return eqs


# ------------------------------------------------------------
# Solving backends
# ------------------------------------------------------------

def feasible_groebner(R, eqs, want_solution=False):
    I = R.ideal(eqs)
    gb = I.groebner_basis()
    if any(g == 1 for g in gb):
        return False, None
    if not want_solution:
        return True, None
    sols = I.variety()
    if len(sols) == 0:
        return False, None
    return True, sols[0]


def _make_sat_solver(backend: str, verbose: bool = True):
    """Return (solver_object, supports_xor, backend_name_used)."""
    backend = backend.lower()

    def log(msg):
        if verbose:
            print(msg)

    if backend == "cryptominisat":
        try:
            from sage.sat.solvers.cryptominisat import CryptoMiniSat
            return CryptoMiniSat(), True, "cryptominisat"
        except Exception as e:
            raise RuntimeError(f"cryptominisat unavailable: {e}")

    if backend == "picosat":
        try:
            from sage.sat.solvers.picosat import PicoSAT
            return PicoSAT(), False, "picosat"
        except Exception:
            try:
                from sage.sat.solvers.picosat import PicoSat
                return PicoSat(), False, "picosat"
            except Exception as e:
                raise RuntimeError(f"picosat unavailable: {e}")

    if backend == "lp":
        from sage.sat.solvers.sat_lp import SatLP

        class SatLPCompat(SatLP):
            # PolyBoRi converter calls var(decision=...). Sage 10.5 SatLP.var() has no such kw.
            def var(self, decision=None):
                return SatLP.var(self)

        return SatLPCompat(), False, "lp"

    if backend == "auto":
        # try cryptominisat -> picosat -> lp
        for b in ("cryptominisat", "picosat", "lp"):
            try:
                sol, xor_ok, name = _make_sat_solver(b, verbose=False)
                log(f"SAT backend used: {name}")
                if not xor_ok:
                    log("Note: backend does not support XOR clauses; forcing pure CNF encoding.")
                return sol, xor_ok, name
            except Exception:
                continue
        raise RuntimeError("No SAT backend available (cryptominisat/picosat/lp all failed).")

    raise ValueError("Unknown --sat_backend. Use auto|cryptominisat|picosat|lp")


def feasible_sat(eqs, backend: str, verbosity: int = 0, want_solution: bool = False):
    """Solve Boolean polynomial system via Sage's ANF→SAT pipeline.

    Sage's documentation states that :func:`sage.sat.boolean_polynomials.solve` returns
    a *list of dictionaries* (models). In practice, depending on Sage version / backend
    combinations, UNSAT (and occasionally SAT) may be returned as a bare boolean.

    We normalize all such cases here.
    """
    from sage.sat.boolean_polynomials import solve as solve_sat

    solver, xor_ok, used = _make_sat_solver(backend, verbose=True)
    print(f"SAT backend used: {used}")
    if not xor_ok:
        print("Note: backend does not support XOR clauses; forcing pure CNF encoding.")

    sols = solve_sat(
        eqs,
        n=1,
        solver=solver,
        s_verbosity=verbosity,
        c_use_xor_clauses=bool(xor_ok),
    )

    # --- Normalize return types ---
    # Expected: list[dict].  Observed in the wild: bool, dict, (sat, model) tuples.
    if isinstance(sols, bool):
        # Most commonly: False means UNSAT.
        if sols is False:
            return False, None
        # True means SAT but no model was returned.
        if want_solution:
            # Try one more time with a fresh solver instance (some backends are stateful).
            solver2, xor_ok2, _ = _make_sat_solver(backend, verbose=False)
            sols2 = solve_sat(
                eqs,
                n=1,
                solver=solver2,
                s_verbosity=verbosity,
                c_use_xor_clauses=bool(xor_ok2),
            )
            if isinstance(sols2, list) and len(sols2) > 0:
                return True, sols2[0]
            raise RuntimeError(
                "SAT backend reported SAT but did not return a model. "
                "Try a different --sat_backend or run with higher verbosity."
            )
        return True, None

    if isinstance(sols, tuple) and len(sols) == 2 and isinstance(sols[0], bool):
        sat, model = sols
        if not sat:
            return False, None
        if want_solution:
            return True, model
        return True, None

    if isinstance(sols, dict):
        # Single model returned directly.
        if want_solution:
            return True, sols
        return True, None

    # Default: list of models.
    try:
        if len(sols) == 0:
            return False, None
    except TypeError:
        # Last resort: interpret truthiness.
        return (bool(sols), None)

    if want_solution:
        return True, sols[0]
    return True, None



def extract_perm_from_solution(sol, N, x):
    """Extract perm[i]=v from an assignment dict sol."""
    perm = [None] * N
    for i in range(N):
        hit = None
        for v in range(N):
            if int(sol.get(x(i, v), 0)) == 1:
                hit = v
                break
        perm[i] = hit
    return perm



def extract_X_from_solution(sol, N, x):
    '''Extract the permutation matrix X_{i,v} from an assignment dict.'''
    F = GF(2)
    return matrix(F, N, N, lambda i, v: int(sol.get(x(i, v), 0)) & 1)


def extract_B_from_solution(sol, dim, b):
    '''Extract the boundary matrix B from an assignment dict (b-variables).'''
    F = GF(2)
    return matrix(F, dim, dim, lambda u, v: int(sol.get(b(u, v), 0)) & 1)


def extract_Y_from_solution(sol, dim, kdim, y):
    '''Extract the kernel witness matrix Y from an assignment dict (y-variables).'''
    F = GF(2)
    return matrix(F, dim, kdim, lambda v, t: int(sol.get(y(v, t), 0)) & 1)


def _diff_positions(M1, M2, limit=20):
    '''Return a short list of positions where matrices differ.'''
    out = []
    for i in range(M1.nrows()):
        for j in range(M1.ncols()):
            if M1[i, j] != M2[i, j]:
                out.append((i, j))
                if len(out) >= limit:
                    return out
    return out


def check_certificate(A0, perm, X, B_model, Y, J, r, *, verbose=True):
    '''Deterministic certificate checks for a SAT witness.

    Checks performed:
      (1) X is a permutation matrix over {0,1} (exactly one 1 per row/col).
      (2) perm agrees with X.
      (3) B_model equals the literal boundary B_true computed from perm.
      (4) Gauge: Y_J = I.
      (5) Kernel: B_true * Y = 0.
      (6) Rank bound: rank(B_true) <= r.

    Raises RuntimeError on failure. Returns B_true on success.
    '''
    N = X.nrows()
    dim = N - 1
    kdim = dim - int(r)

    # (1) permutation matrix (over integers, not mod 2)
    for i in range(N):
        s = sum(int(X[i, v]) for v in range(N))
        if s != 1:
            raise RuntimeError(f"Certificate failed: row {i} of X has sum {s}, expected 1.")
    for v in range(N):
        s = sum(int(X[i, v]) for i in range(N))
        if s != 1:
            raise RuntimeError(f"Certificate failed: column {v} of X has sum {s}, expected 1.")

    # (2) perm agrees with X
    for i in range(N):
        v = perm[i]
        if v is None:
            raise RuntimeError(f"Certificate failed: perm[{i}] is None.")
        if int(X[i, v]) != 1:
            raise RuntimeError(f"Certificate failed: perm[{i}]={v} but X[{i},{v}]=0.")
        # ensure uniqueness in that row
        for w in range(N):
            if w != v and int(X[i, w]) == 1:
                raise RuntimeError(f"Certificate failed: row {i} has another 1 at column {w}.")

    # (3) boundary consistency: b-variables match literal boundary from perm
    rr, B_true = boundary_rank_of_perm(A0, perm)
    if B_model.nrows() != dim or B_model.ncols() != dim:
        raise RuntimeError("Certificate failed: B_model has wrong shape.")
    if B_model != B_true:
        pos = _diff_positions(B_model, B_true, limit=20)
        raise RuntimeError(f"Certificate failed: B_model != B_true. First differing positions: {pos}")

    # (4) gauge Y_J = I
    if len(J) != kdim:
        raise RuntimeError(f"Certificate failed: |J|={len(J)} != kdim={kdim}.")
    for t in range(kdim):
        if Y[J[t], t] != 1:
            raise RuntimeError(f"Certificate failed: gauge Y[{J[t]},{t}] != 1.")
        for s in range(kdim):
            if s != t and Y[J[s], t] != 0:
                raise RuntimeError(f"Certificate failed: gauge Y[{J[s]},{t}] != 0.")

    # (5) kernel check
    Z = B_true * Y
    if Z != zero_matrix(GF(2), dim, kdim):
        for i in range(dim):
            for j in range(kdim):
                if Z[i, j] != 0:
                    raise RuntimeError(f"Certificate failed: (B*Y)[{i},{j}] = 1 (should be 0).")

    # (6) rank bound (redundant, but explicit)
    if rr > int(r):
        raise RuntimeError(f"Certificate failed: rank(B_true)={rr} > r={r}.")

    if verbose:
        print("Certificate checks: OK (X permutation; B matches boundary; Y_J=I; B*Y=0).")

    return B_true


# ------------------------------------------------------------
# Self-test utilities
# ------------------------------------------------------------

def _format_solve_sat_result(obj, maxlen: int = 200):
    """Pretty summary of the return value of solve_sat for debugging."""
    if isinstance(obj, bool):
        return f"bool({obj})"
    if isinstance(obj, dict):
        return f"dict(keys={len(obj)})"
    if isinstance(obj, tuple):
        return f"tuple(len={len(obj)})"
    try:
        n = len(obj)
        # avoid dumping big models
        head = obj[0] if n > 0 else None
        hs = str(head)
        if len(hs) > maxlen:
            hs = hs[:maxlen] + "..."
        return f"{type(obj).__name__}(len={n}, head={hs})"
    except Exception:
        s = str(obj)
        if len(s) > maxlen:
            s = s[:maxlen] + "..."
        return f"{type(obj).__name__}({s})"


def _boundary_mod2_matrix_fast_symmetric_zero_diag(T):
    """Compute ∂(T) via the closed-form parity formula used in constraints.

    Assumes T is symmetric with zero diagonal (adjacency-like). Returns (N-1)x(N-1).
    """
    F = GF(2)
    N = T.nrows()
    dim = N - 1
    B = zero_matrix(F, dim, dim)
    for u in range(dim):
        for v in range(u + 1, dim):
            s = F(0)
            if ((u + 1) & 1):
                s += T[u + 1, v + 1]
            if (((v - u) & 1)):
                s += T[u, v + 1]
            if (((N - 1 - v) & 1)):
                s += T[u, v]
            B[u, v] = s
            B[v, u] = s
    # diagonal stays 0
    return B


def run_selftest(sat_backend: str, sat_verbosity: int = 0, trials: int = 20):
    """Run minimal internal consistency checks and exit.

    Checks performed:
      (1) Boundary parity formula matches the definition (XOR-sum of principal minors)
          on random symmetric zero-diagonal matrices for small N.
      (2) Probe sage.sat.boolean_polynomials.solve return types on tiny SAT/UNSAT instances,
          and verify our feasible_sat() normalization behaves correctly.
      (3) If sat_backend resolves to cryptominisat, sanity-check pycryptosat binding by
          solving a one-clause SAT instance.

    This does *not* certify UNSAT instances; it is a regression/sanity test.
    """
    print("=== selftest: boundary parity formula ===")
    rng = random.Random(int(0))

    for N in (6, 7, 8):
        ok = True
        for t in range(trials):
            A = zero_matrix(GF(2), N, N)
            for i in range(N):
                for j in range(i + 1, N):
                    bit = rng.randint(0, 1)
                    A[i, j] = bit
                    A[j, i] = bit
            # zero diagonal already
            B_def = boundary_mod2_matrix(A)
            B_fast = _boundary_mod2_matrix_fast_symmetric_zero_diag(A)
            if B_def != B_fast:
                ok = False
                print(f"FAIL: N={N}, trial={t}")
                print("B_def:")
                print(B_def)
                print("B_fast:")
                print(B_fast)
                break
        print(f"  N={N}: {'OK' if ok else 'FAIL'}")
        if not ok:
            raise RuntimeError("Boundary parity formula selftest failed.")

    print("=== selftest: solve_sat return types + feasible_sat normalization ===")
    from sage.sat.boolean_polynomials import solve as solve_sat

    R = BooleanPolynomialRing(1, "x")
    x = R.gen(0)
    eq_sat = [x + 1]      # x = 1
    eq_unsat = [x, x + 1] # x = 0 and x = 1

    solver, xor_ok, used = _make_sat_solver(sat_backend, verbose=True)
    print(f"selftest SAT backend resolved to: {used} (xor_ok={xor_ok})")

    raw_sat = solve_sat(eq_sat, n=1, solver=solver, s_verbosity=int(sat_verbosity),
                        c_use_xor_clauses=bool(xor_ok))
    print("  solve_sat(SAT)  ->", _format_solve_sat_result(raw_sat))

    # fresh solver (some backends are stateful)
    solver2, xor_ok2, used2 = _make_sat_solver(sat_backend, verbose=False)
    raw_unsat = solve_sat(eq_unsat, n=1, solver=solver2, s_verbosity=int(sat_verbosity),
                          c_use_xor_clauses=bool(xor_ok2))
    print("  solve_sat(UNSAT)->", _format_solve_sat_result(raw_unsat))

    sat1, model1 = feasible_sat(eq_sat, backend=sat_backend, verbosity=int(sat_verbosity), want_solution=True)
    print("  feasible_sat(SAT)   =", sat1, ", model?", model1 is not None)
    if not sat1:
        raise RuntimeError("feasible_sat reported UNSAT on a SAT instance.")

    sat2, model2 = feasible_sat(eq_unsat, backend=sat_backend, verbosity=int(sat_verbosity), want_solution=False)
    print("  feasible_sat(UNSAT) =", sat2)
    if sat2:
        raise RuntimeError("feasible_sat reported SAT on an UNSAT instance.")

    if used == "cryptominisat":
        print("=== selftest: pycryptosat binding ===")
        try:
            from pycryptosat import Solver
            def _pyints(seq):
                return [int(z) for z in seq]
            s = Solver()
            s.add_clause(_pyints([1]))
            res = s.solve()
            print("  pycryptosat ok:", res)
        except Exception as e:
            print("  pycryptosat import/solve failed:", repr(e))
            raise

    print("=== selftest: PASS ===")

# ------------------------------------------------------------
# CLI
# ------------------------------------------------------------

def parse_J_list(s: str) -> list:
    return [int(t) for t in s.split(",") if t.strip() != ""]

def _sanitize_for_filename(s: str) -> str:
    # Keep filenames portable across host/container filesystems.
    return "".join(c if (c.isalnum() or c in "._-") else "_" for c in str(s))

def _read_int_file(path: str):
    try:
        with open(path, "r") as f:
            txt = f.read().strip()
        if txt == "":
            return None
        return int(txt.split()[0])
    except FileNotFoundError:
        return None

def _write_int_file_atomic(path: str, value: int):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(int(value)) + "\n")
    os.replace(tmp, path)

def _start_heartbeat(label: str, interval_seconds: float):
    """
    Print periodic 'still running' messages while a long SAT solve is in progress.
    Returns a threading.Event; call stop.set() to stop the heartbeat.
    """
    stop = threading.Event()
    t0 = time.time()
    interval = float(interval_seconds)

    def _beat():
        while not stop.wait(interval):
            dt = time.time() - t0
            ts = datetime.now().isoformat(timespec="seconds")
            print(f"[{ts}] {label} still running (+{dt:.1f}s)")
            sys.stdout.flush()

    th = threading.Thread(target=_beat, daemon=True)
    th.start()
    return stop


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--graph", type=str, default="rook",
                    help="rook | shrikhande | petersen | atlas:ID")
    ap.add_argument("--rank", type=int, default=6, help="target rank r (solve rank(B)<=r)")

    ap.add_argument("--solver", type=str, choices=["sat", "groebner"], default="sat")
    ap.add_argument("--sat_backend", type=str, default="auto",
                    help="auto | cryptominisat | picosat | lp")

    ap.add_argument("--J", type=str, default="", help="comma-separated pivot rows J (size kdim)")
    ap.add_argument("--scan_all_J", action="store_true", help="scan all J subsets (early-exit on SAT)")
    ap.add_argument("--offset", type=int, default=0, help="process J with index ≡ offset (mod stride)")
    ap.add_argument("--stride", type=int, default=1, help="stride for parallel scanning")

    ap.add_argument("--resume", action="store_true",
                    help="During --scan_all_J: resume from per-worker state_file (skip gidx <= last_done).")
    ap.add_argument("--state_file", type=str, default="",
                    help="During --scan_all_J: per-worker state file (stores last DONE gidx). "
                         "If empty, defaults to /home/sage/notebooks/state_{graph}_r{r}_stride{stride}_off{offset}.txt")
    ap.add_argument("--stop_file", type=str, default="",
                    help="During --scan_all_J: if this file exists, exit before starting next case. On SAT, write it.")

    ap.add_argument("--want_solution", action="store_true", help="attempt to extract a solution")
    ap.add_argument("--sat_verbosity", type=int, default=0, help="SAT solver verbosity")
    ap.add_argument("--selftest", action="store_true", help="run internal self-tests and exit")

    ap.add_argument("--rook_witness_check", action="store_true",
                    help="verify the known rook rank-6 witness and print a good pivot set J")
    ap.add_argument("--progress_every", type=int, default=50,
          help="During --scan_all_J, print 'scanned J index ...' every k cases (default 50).")
    ap.add_argument("--heartbeat", type=float, default=0.0,
                help="If > 0, print a heartbeat every this many seconds while solving the current J.")



    args = ap.parse_args()

    if args.selftest:
        run_selftest(args.sat_backend, sat_verbosity=int(args.sat_verbosity))
        return

    A0 = load_graph_GF2(args.graph)
    N = A0.nrows()
    r = int(args.rank)
    dim = N - 1
    kdim = dim - r
    if kdim <= 0:
        raise ValueError("Need rank r <= N-2")

    print(f"Graph={args.graph}, N={N}, dim={dim}, target rank<= {r}, kernel dim>= {kdim}")
    print(f"Solver={args.solver}")

    # witness sanity check (rook only, but harmless otherwise)
    if args.rook_witness_check:
        if args.graph != "rook":
            print("rook_witness_check is intended for --graph rook")
            return
        witness = [5, 13, 6, 10, 8, 4, 7, 11, 9, 1, 15, 3, 0, 12, 14, 2]
        rr, B = boundary_rank_of_perm(A0, witness)
        print("Rook witness boundary rank =", rr)
        K = B.right_kernel().basis_matrix().transpose()  # dim x kdim
        print("Computed kernel dimension =", K.ncols())
        if K.ncols() != kdim:
            print("Warning: kernel dimension != kdim; check r or construction")
        # Find a pivot set J of size kdim with det(K_J)=1
        found = None
        rows = list(range(dim))
        for Jset in Subsets(rows, kdim):
            JJ = list(Jset)
            M = K.matrix_from_rows(JJ)
            if M.det() == 1:
                found = JJ
                break
        print("Example pivot row set J for gauge (Y_J invertible):", found)
        return

    # Build polynomial ring + base equations
    R, x, b, y, dim, kdim = make_variable_ring(N, r)

    eqs = []
    eqs += permutation_constraints(N, x)

    Ap_polys = build_Ap_polys(A0, x, R)
    eqs += boundary_entry_constraints_from_Ap_fast(N, dim, Ap_polys, b, R)

    eqs += kernel_constraints(dim, kdim, b, y)

    # Choose solver function
    def run_solver(eqsJ):
        if args.solver == "groebner":
            return feasible_groebner(R, eqsJ, want_solution=args.want_solution)
        # sat
        return feasible_sat(
            eqsJ,
            backend=args.sat_backend,
            verbosity=int(args.sat_verbosity),
            want_solution=args.want_solution,
        )

    # Single J mode
    if args.J:
        J = parse_J_list(args.J)
        if len(J) != kdim:
            raise ValueError(f"Need |J| = kdim = {kdim}")
        eqsJ = eqs + gauge_constraints(J, kdim, y)
        sat, sol = run_solver(eqsJ)
        print("SAT?", sat)
        if sat and sol is not None:
            perm = extract_perm_from_solution(sol, N, x)
            print("Found perm:", perm)

            # Deterministic witness certification (independent of solver internals)
            X = extract_X_from_solution(sol, N, x)
            Bm = extract_B_from_solution(sol, dim, b)
            Y = extract_Y_from_solution(sol, dim, kdim, y)
            B_true = check_certificate(A0, perm, X, Bm, Y, J, r, verbose=True)

            rr = B_true.rank()
            print("Verified boundary rank:", rr)
        return

    # Scan-all-J mode
    if args.scan_all_J:
        rows = list(range(dim))

        stride = int(args.stride)
        offset = int(args.offset)
        if stride < 1:
            raise ValueError("--stride must be >= 1")
        if offset < 0 or offset >= stride:
            raise ValueError("--offset must satisfy 0 <= offset < stride")

        stop_file = str(args.stop_file) if args.stop_file else ""

        if args.state_file:
            state_file = str(args.state_file)
        else:
            gname = _sanitize_for_filename(str(args.graph))
            state_file = f"/home/sage/notebooks/state_{gname}_r{r}_stride{stride}_off{offset}.txt"

        last_done = None
        resume_local = 0
        if args.resume and state_file:
            last_done = _read_int_file(state_file)
            if last_done is not None:
                if last_done < offset or ((last_done - offset) % stride) != 0:
                    print(f"Warning: ignoring state_file={state_file} (last_done={last_done} not compatible with off={offset}, stride={stride})")
                    last_done = None
                else:
                    resume_local = (last_done - offset) // stride + 1
                    print(f"Resuming: state_file={state_file} last_done_gidx={last_done} -> start_local={resume_local}")
                    sys.stdout.flush()

        gidx = 0          # global index in Subsets(rows, kdim) enumeration
        local = 0         # local count of cases processed by this worker
        local = resume_local
        for Jset in Subsets(rows, kdim):
            if stop_file and os.path.exists(stop_file):
                print(f"Stop file exists ({stop_file}); exiting off={offset} stride={stride}.")
                sys.stdout.flush()
                return

            if last_done is not None and gidx <= last_done:
                gidx += 1
                continue
            if (gidx - offset) % stride != 0:
                gidx += 1
                continue
            J = list(Jset)

            # progress banner at start of each case
            ts0 = datetime.now().isoformat(timespec="seconds")
            label = f"gidx={gidx} local={local} off={offset} stride={stride} J={J}"
            print(f"[{ts0}] START {label}")
            sys.stdout.flush()

            hb_stop = None
            if float(args.heartbeat) > 0.0:
                hb_stop = _start_heartbeat(label, float(args.heartbeat))

            t0 = time.time()
            try:
                eqsJ = eqs + gauge_constraints(J, kdim, y)
                sat, sol = run_solver(eqsJ)
            finally:
                if hb_stop is not None:
                    hb_stop.set()

            dt = time.time() - t0
            ts1 = datetime.now().isoformat(timespec="seconds")
            print(f"[{ts1}] DONE  {label} sat={sat} dt={dt:.1f}s")
            sys.stdout.flush()

            # Persist progress for crash-safe resume.
            if state_file:
                try:
                    _write_int_file_atomic(state_file, gidx)
                    last_done = gidx
                except Exception as e:
                    print("Warning: could not write state_file:", state_file, "err:", repr(e))
                    sys.stdout.flush()

            if sat:
                print("SAT found for J =", J, "(gidx", gidx, ", local", local, ", off", offset, ", stride", stride, ")")
                sys.stdout.flush()

                # Signal other workers to stop (if configured).
                if stop_file:
                    try:
                        with open(stop_file, "w") as f:
                            f.write(f"SAT gidx={gidx} off={offset} stride={stride} J={J}\n")
                    except Exception as e:
                        print("Warning: could not write stop_file:", stop_file, "err:", repr(e))
                    sys.stdout.flush()

                if args.want_solution:
                    # Defensive: some backends may report SAT but not return a model here.
                    if sol is None:
                        print("SAT reported but no model returned; rerunning once to extract model...")
                        sys.stdout.flush()
                        sat2, sol2 = run_solver(eqsJ)
                        if (not sat2) or (sol2 is None):
                            raise RuntimeError("SAT found but no model returned; cannot certify witness.")
                        sol = sol2

                    perm = extract_perm_from_solution(sol, N, x)
                    print("Found perm:", perm)

                    X = extract_X_from_solution(sol, N, x)
                    Bm = extract_B_from_solution(sol, dim, b)
                    Y  = extract_Y_from_solution(sol, dim, kdim, y)

                    B_true = check_certificate(A0, perm, X, Bm, Y, J, r, verbose=True)
                    print("Verified boundary rank:", B_true.rank())
                    sys.stdout.flush()
                else:
                    print("(Run with --want_solution to extract and certify a witness.)")
                    sys.stdout.flush()

                return


            if int(args.progress_every) > 0 and (local % int(args.progress_every) == 0):
                print("scanned local", local, "at gidx", gidx)
                sys.stdout.flush()

            local += 1
            gidx += 1


        print(f"No SAT case found for off={offset} stride={stride} (processed {local} cases).")
        return

    print("No J specified. Use --J ... or --scan_all_J.")


if __name__ == "__main__":
    main()
