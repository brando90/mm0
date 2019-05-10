import data.bitvec

def bitvec.singleton (b : bool) : bitvec 1 := vector.cons b vector.nil
local notation `S` := bitvec.singleton

@[reducible] def byte := bitvec 8

def byte.to_nat : byte → ℕ := bitvec.to_nat

@[reducible] def qword := bitvec 64

@[reducible] def word := bitvec 32

def of_bits : list bool → nat
| [] := 0
| (b :: l) := nat.bit b (of_bits l)

inductive split_bits : ℕ → list (Σ n, bitvec n) → Prop
| nil : split_bits 0 []
| zero {b l} : split_bits b l → split_bits b (⟨0, vector.nil⟩ :: l)
| succ {b n l bs} :
  split_bits b (⟨n, bs⟩ :: l) →
  split_bits (nat.div2 b) (⟨n + 1, vector.cons (nat.bodd b) bs⟩ :: l)

def from_list_byte : list byte → ℕ
| [] := 0
| (b :: l) := b.to_nat + 0x100 * from_list_byte l

inductive bits_to_byte {n} (m) (w : bitvec n) : list byte → Prop
| mk (bs : vector byte m) : split_bits w.to_nat (bs.1.map (λ b, ⟨8, b⟩)) →
  bits_to_byte bs.1

def word.to_list_byte : word → list byte → Prop := bits_to_byte 4

def qword.to_list_byte : qword → list byte → Prop := bits_to_byte 8

def EXTS_aux : list bool → bool → ∀ {m}, bitvec m
| []     b m     := vector.repeat b _
| (a::l) _ 0     := vector.nil
| (a::l) _ (m+1) := vector.cons a (EXTS_aux l a)

def EXTS {m n} (v : bitvec n) : bitvec m := EXTS_aux v.1 ff

def EXTZ_aux : list bool → ∀ {m}, bitvec m
| []     m     := vector.repeat ff _
| (a::l) 0     := vector.nil
| (a::l) (m+1) := vector.cons a (EXTS_aux l a)

def EXTZ {m n} (v : bitvec n) : bitvec m := EXTZ_aux v.1

def bitvec.update0_aux : list bool → ∀ {n}, bitvec n → bitvec n
| []     n     v := v
| (a::l) 0     v := v
| (a::l) (n+1) v := vector.cons a (bitvec.update0_aux l v.tail)

def bitvec.update_aux : ℕ → list bool → ∀ {n}, bitvec n → bitvec n
| 0     l n     v := bitvec.update0_aux l v
| (m+1) l 0     v := v
| (m+1) l (n+1) v := vector.cons v.head (bitvec.update_aux m l v.tail)

def bitvec.update {m n} (v1 : bitvec n) (index : ℕ) (v2 : bitvec m) : bitvec n :=
bitvec.update_aux index v2.1 v1

structure pstate_result (σ α : Type*) :=
(safe : Prop)
(P : α → σ → Prop)
(good : safe → ∃ a s, P a s)

def pstate (σ α : Type*) := σ → pstate_result σ α

inductive pstate_pure_P {σ α : Type*} (a : α) (s : σ) : α → σ → Prop
| mk : pstate_pure_P a s

inductive pstate_map_P {σ α β} (f : α → β) (x : pstate_result σ α) : β → σ → Prop
| mk (a s') : x.P a s' → pstate_map_P (f a) s'

def pstate_bind_safe {σ α β} (x : pstate σ α) (f : α → pstate σ β) (s : σ) : Prop :=
(x s).safe ∧ ∀ a s', (x s).P a s' → (f a s').safe

def pstate_bind_P {σ α β} (x : pstate σ α) (f : α → pstate σ β) (s : σ) (b : β) (s' : σ) : Prop :=
∃ a s1, (x s).P a s1 ∧ (f a s1).P b s'

instance {σ} : monad (pstate σ) :=
{ pure := λ α a s, ⟨true, pstate_pure_P a s, λ _, ⟨_, _, ⟨a, s⟩⟩⟩,
  map := λ α β f x s, ⟨(x s).1, pstate_map_P f (x s), λ h,
    let ⟨a, s', h⟩ := (x s).good h in ⟨_, _, ⟨_, _, _, h⟩⟩⟩,
  bind := λ α β x f s, ⟨pstate_bind_safe x f s, pstate_bind_P x f s,
    λ ⟨h₁, h₂⟩, let ⟨a, s1, hx⟩ := (x s).good h₁,
      ⟨b, s2, hf⟩ := (f a s1).good (h₂ a s1 hx) in
      ⟨b, s2, ⟨_, _, hx, hf⟩⟩⟩ }

def pstate.lift {σ α} (f : σ → α → σ → Prop) : pstate σ α := λ s, ⟨_, f s, id⟩

inductive pstate.get' {σ} (s : σ) : σ → σ → Prop
| mk : pstate.get' s s
def pstate.get {σ} : pstate σ σ := pstate.lift pstate.get'

def pstate.put {σ} (s : σ) : pstate σ unit := pstate.lift $ λ _ _, eq s

def pstate.assert {σ α} (p : σ → α → Prop) : pstate σ α :=
pstate.lift $ λ s a s', p s a ∧ s = s'

def pstate.modify {σ} (f : σ → σ) : pstate σ unit :=
pstate.lift $ λ s _ s', s' = f s

def pstate.any {σ α} : pstate σ α := pstate.assert $ λ _ _, true

def pstate.fail {σ α} : pstate σ α := pstate.assert $ λ _ _, false

namespace x86

@[reducible] def regnum := bitvec 4

def RAX : regnum := 0
def RCX : regnum := 1
def RSP : regnum := 4
def RBP : regnum := 5

def REX := option (bitvec 4)

def REX.to_nat : REX → ℕ
| none := 0
| (some r) := r.to_nat

def REX.W (r : REX) : bool := option.cases_on r ff (λ r, vector.nth r 3)
def REX.R (r : REX) : bool := option.cases_on r ff (λ r, vector.nth r 2)
def REX.X (r : REX) : bool := option.cases_on r ff (λ r, vector.nth r 1)
def REX.B (r : REX) : bool := option.cases_on r ff (λ r, vector.nth r 0)

def rex_reg (b : bool) (r : bitvec 3) : regnum := (bitvec.append r (S b) : _)

structure scale_index :=
(scale : bitvec 2)
(index : regnum)

inductive base | none | rip | reg (reg : regnum)

inductive RM : Type
| reg : regnum → RM
| mem : option scale_index → base → qword → RM

def RM.is_mem : RM → Prop
| (RM.mem _ _ _) := true
| _ := false

@[reducible] def Mod := bitvec 2

inductive read_displacement : Mod → qword → list byte → Prop
| disp0 : read_displacement 0 0 []
| disp8 (b : byte) : read_displacement 1 (EXTS b) [b]
| disp32 (w : word) (l) : w.to_list_byte l → read_displacement 2 (EXTS w) l

def read_sib_displacement (mod : Mod) (bbase : regnum) (w : qword)
  (Base : base) (l : list byte) : Prop :=
if bbase = RBP ∧ mod = 0 then
  ∃ b, w = EXTS b ∧ Base = base.none ∧ l = [b]
else read_displacement mod w l ∧ Base = base.reg bbase

inductive read_SIB (rex : REX) (mod : Mod) : RM → list byte → Prop
| mk (b : byte) (bs ix SS) (disp bbase' l) :
  split_bits b.to_nat [⟨3, bs⟩, ⟨3, ix⟩, ⟨2, SS⟩] →
  let bbase := rex_reg rex.B bs,
      index := rex_reg rex.X ix,
      scaled_index : option scale_index :=
        if index = RSP then none else some ⟨SS, index⟩ in
  read_sib_displacement mod bbase disp bbase' l →
  read_SIB (RM.mem scaled_index bbase' disp) l

inductive read_ModRM (rex : REX) : regnum → RM → list byte → Prop
| imm32 (b : byte) (reg_opc : bitvec 3) (i : word) (disp) :
  split_bits b.to_nat [⟨3, 0b101⟩, ⟨3, reg_opc⟩, ⟨2, 0b00⟩] →
  i.to_list_byte disp →
  read_ModRM (rex_reg rex.R reg_opc)
    (RM.mem none base.rip (EXTS i)) (b :: disp)
| reg (b : byte) (rm reg_opc : bitvec 3) :
  split_bits b.to_nat [⟨3, rm⟩, ⟨3, reg_opc⟩, ⟨2, 0b11⟩] →
  read_ModRM (rex_reg rex.R reg_opc) (RM.reg (rex_reg rex.B rm)) [b]
| sib (b : byte) (reg_opc : bitvec 3) (mod : Mod) (sib) (l) :
  split_bits b.to_nat [⟨3, 0b100⟩, ⟨3, reg_opc⟩, ⟨2, mod⟩] →
  read_SIB rex mod sib l →
  read_ModRM (rex_reg rex.R reg_opc) sib (b :: l)
| mem (b : byte) (rm reg_opc : bitvec 3) (mod : Mod) (disp l) :
  split_bits b.to_nat [⟨3, rm⟩, ⟨3, reg_opc⟩, ⟨2, mod⟩] → rm ≠ 0b100 →
  read_displacement mod disp l →
  read_ModRM (rex_reg rex.B reg_opc)
    (RM.mem none (base.reg (rex_reg rex.B rm)) disp) (b :: l)

inductive read_opcode_ModRM (rex : REX) : bitvec 3 → RM → list byte → Prop
| mk (rn : regnum) (rm l v b) :
  read_ModRM rex rn rm l →
  split_bits rn.to_nat [⟨3, v⟩, ⟨1, b⟩] →
  read_opcode_ModRM v rm l

-- obsolete group 1-4 prefixes omitted
inductive read_prefixes : REX → list byte → Prop
| nil : read_prefixes none []
| rex (b : byte) (rex) :
  split_bits b.to_nat [⟨4, rex⟩, ⟨4, 0b100⟩] →
  read_prefixes (some rex) [b]

@[derive decidable_eq]
inductive wsize
| Sz8 (have_rex : bool)
| Sz16 | Sz32 | Sz64
open wsize

def wsize.to_nat : wsize → ℕ
| (Sz8 _) := 8
| Sz16 := 16
| Sz32 := 32
| Sz64 := 64

inductive read_imm8 : qword → list byte → Prop
| mk (b : byte) : read_imm8 (EXTS b) [b]

inductive read_imm16 : qword → list byte → Prop
| mk (w : bitvec 16) (l) : bits_to_byte 2 w l → read_imm16 (EXTS w) l

inductive read_imm32 : qword → list byte → Prop
| mk (w : word) (l) : w.to_list_byte l → read_imm32 (EXTS w) l

def read_imm : wsize → qword → list byte → Prop
| (Sz8 _) := read_imm8
| Sz16 := read_imm16
| Sz32 := read_imm32
| Sz64 := λ _ _, false

def read_full_imm : wsize → qword → list byte → Prop
| (Sz8 _) := read_imm8
| Sz16 := read_imm16
| Sz32 := read_imm32
| Sz64 := λ w l, w.to_list_byte l

def op_size (have_rex w v : bool) : wsize :=
if ¬ v then Sz8 have_rex else
if w then Sz64 else
-- if override then Sz16 else
Sz32

inductive dest_src
| Rm_i : RM → qword → dest_src
| Rm_r : RM → regnum → dest_src
| R_rm : regnum → RM → dest_src
open dest_src

inductive imm_rm
| rm : RM → imm_rm
| imm : qword → imm_rm

inductive unop | dec | inc | not | neg

inductive binop
| add | or  | adc | sbb | and | sub | xor | cmp
| rol | ror | rcl | rcr | shl | shr | tst | sar

inductive binop.bits : binop → bitvec 4 → Prop
| add : binop.bits binop.add 0x0
| or  : binop.bits binop.or  0x1
| adc : binop.bits binop.adc 0x2
| sbb : binop.bits binop.sbb 0x3
| and : binop.bits binop.and 0x4
| sub : binop.bits binop.sub 0x5
| xor : binop.bits binop.xor 0x6
| cmp : binop.bits binop.cmp 0x7
| rol : binop.bits binop.rol 0x8
| ror : binop.bits binop.ror 0x9
| rcl : binop.bits binop.rcl 0xa
| rcr : binop.bits binop.rcr 0xb
| shl : binop.bits binop.shl 0xc
| shr : binop.bits binop.shr 0xd
| tst : binop.bits binop.tst 0xe
| sar : binop.bits binop.sar 0xf

inductive basic_cond
| o | b | e | na | s | l | ng

inductive basic_cond.bits : basic_cond → bitvec 3 → Prop
| o  : basic_cond.bits basic_cond.o  0x0
| b  : basic_cond.bits basic_cond.b  0x1
| e  : basic_cond.bits basic_cond.e  0x2
| na : basic_cond.bits basic_cond.na 0x3
| s  : basic_cond.bits basic_cond.s  0x4
| l  : basic_cond.bits basic_cond.l  0x6
| ng : basic_cond.bits basic_cond.ng 0x7

inductive cond_code
| always
| pos : basic_cond → cond_code
| neg : basic_cond → cond_code

def cond_code.mk : bool → basic_cond → cond_code
| ff := cond_code.pos
| tt := cond_code.neg

inductive cond_code.bits : cond_code → bitvec 4 → Prop
| mk (v : bitvec 4) (b c code) :
  split_bits v.to_nat [⟨3, c⟩, ⟨1, S b⟩] →
  basic_cond.bits code c →
  cond_code.bits (cond_code.mk b code) v

inductive ast
| unop : unop → wsize → RM → ast
| binop : binop → wsize → dest_src → ast
| push : imm_rm → ast
| pop : RM → ast
| movsx : wsize → dest_src → wsize → ast
| movzx : wsize → dest_src → wsize → ast
| jcc : cond_code → qword → ast
| xchg : wsize → RM → regnum → ast
| cmov : cond_code → wsize → dest_src → ast
| lea : wsize → dest_src → ast
| ret : qword → ast
| leave : ast
| int : byte → ast
| loop : cond_code → qword → ast
| call : imm_rm → ast
| cmc
| clc
| stc
| mul : wsize → RM → ast
| div : wsize → RM → ast
| jump : RM → ast
| setcc : cond_code → bool → RM → ast
| cmpxchg : wsize → RM → regnum → ast
| xadd : wsize → RM → regnum → ast

def ast.mov := ast.cmov cond_code.always

inductive decode_misc1 (v : bool) (sz : wsize) (r : RM) :
  bool → bitvec 3 → ast → list byte → Prop
| test (imm l) : read_imm sz imm l →
  decode_misc1 ff 0b000 (ast.binop binop.tst sz (Rm_i r imm)) l
| not : decode_misc1 ff 0b010 (ast.unop unop.not sz r) []
| neg : decode_misc1 ff 0b011 (ast.unop unop.neg sz r) []
| mul : decode_misc1 ff 0b100 (ast.mul sz r) []
| div : decode_misc1 ff 0b110 (ast.div sz r) []
| inc : decode_misc1 tt 0b000 (ast.unop unop.inc sz r) []
| dec : decode_misc1 tt 0b001 (ast.unop unop.dec sz r) []
| call : v → decode_misc1 tt 0b010 (ast.call (imm_rm.rm r)) []
| jump : v → decode_misc1 tt 0b100 (ast.jump r) []
| push : v → decode_misc1 tt 0b110 (ast.push (imm_rm.rm r)) []

inductive decode_two (rex : REX) : ast → list byte → Prop
| cmov (b : byte) (c reg r l code) :
  split_bits b.to_nat [⟨4, c⟩, ⟨4, 0x4⟩] →
  let sz := op_size tt rex.W tt in
  read_ModRM rex reg r l →
  cond_code.bits code c →
  decode_two (ast.cmov code sz (R_rm reg r)) (b :: l)
| jcc (b : byte) (c imm l code) :
  split_bits b.to_nat [⟨4, c⟩, ⟨4, 0x8⟩] →
  let sz := op_size tt rex.W tt in
  read_imm32 imm l →
  cond_code.bits code c →
  decode_two (ast.jcc code imm) (b :: l)
| setcc (b : byte) (c reg r l code) :
  split_bits b.to_nat [⟨4, c⟩, ⟨4, 0x9⟩] →
  let sz := op_size tt rex.W tt in
  read_ModRM rex reg r l →
  cond_code.bits code c →
  decode_two (ast.setcc code rex.is_some r) (b :: l)
| cmpxchg (b : byte) (v reg r l) :
  split_bits b.to_nat [⟨1, S v⟩, ⟨7, 0b1011000⟩] →
  let sz := op_size rex.is_some rex.W v in
  read_ModRM rex reg r l →
  decode_two (ast.cmpxchg sz r reg) (b :: l)
| movsx (b : byte) (v s reg r l) :
  split_bits b.to_nat [⟨1, S v⟩, ⟨2, 0b11⟩, ⟨1, S s⟩, ⟨4, 0xb⟩] →
  let sz2 := op_size rex.is_some rex.W tt,
      sz := if v then Sz16 else Sz8 rex.is_some in
  read_ModRM rex reg r l →
  decode_two ((if s then ast.movsx else ast.movzx) sz (R_rm reg r) sz2) (b :: l)
| xadd (b : byte) (v reg r l) :
  split_bits b.to_nat [⟨1, S v⟩, ⟨7, 0b1100000⟩] →
  let sz := op_size rex.is_some rex.W v in
  read_ModRM rex reg r l →
  decode_two (ast.xadd sz r reg) (b :: l)

inductive decode_aux (rex : REX) : ast → list byte → Prop
| binop1 (b : byte) (v d opc reg r l op) :
  split_bits b.to_nat [⟨1, S v⟩, ⟨1, S d⟩, ⟨1, 0b0⟩, ⟨3, opc⟩, ⟨2, 0b00⟩] →
  let sz := op_size rex.is_some rex.W v in
  read_ModRM rex reg r l →
  let src_dst := if d then R_rm reg r else Rm_r r reg in
  binop.bits op (EXTZ opc) →
  decode_aux (ast.binop op sz src_dst) (b :: l)
| binop_imm_rax (b : byte) (v opc imm l op) :
  split_bits b.to_nat [⟨1, S v⟩, ⟨2, 0b10⟩, ⟨3, opc⟩, ⟨2, 0b00⟩] →
  let sz := op_size rex.is_some rex.W v in
  binop.bits op (EXTZ opc) →
  read_imm sz imm l →
  decode_aux (ast.binop op sz (Rm_i (RM.reg RAX) imm)) (b :: l)
| two (a l) : decode_two rex a l → decode_aux a (0x0f :: l)
| push_rm (b : byte) (r) :
  split_bits b.to_nat [⟨3, r⟩, ⟨5, 0b01010⟩] →
  decode_aux (ast.push (imm_rm.rm (RM.reg (rex_reg rex.B r)))) [b]
| pop (b : byte) (r) :
  split_bits b.to_nat [⟨3, r⟩, ⟨5, 0b01011⟩] →
  decode_aux (ast.pop (RM.reg (rex_reg rex.B r))) [b]
| movsx (reg r l) :
  read_ModRM rex reg r l →
  decode_aux (ast.movsx Sz32 (R_rm reg r) Sz64) (0x63 :: l)
| push_imm (b : byte) (x imm l) :
  split_bits b.to_nat [⟨1, 0b0⟩, ⟨1, S x⟩, ⟨6, 0b011010⟩] →
  read_imm (if x then Sz8 ff else Sz32) imm l →
  decode_aux (ast.push (imm_rm.imm imm)) (b :: l)
| jcc8 (b : byte) (c code imm l) :
  split_bits b.to_nat [⟨4, c⟩, ⟨4, 0b0111⟩] →
  cond_code.bits code c →
  read_imm8 imm l →
  decode_aux (ast.jcc code imm) (b :: l)
| binop_imm (b : byte) (v opc r l1 imm l2 op) :
  split_bits b.to_nat [⟨1, S v⟩, ⟨7, 0b1000000⟩] →
  let sz := op_size rex.is_some rex.W v in
  read_opcode_ModRM rex opc r l1 →
  read_imm sz imm l2 →
  binop.bits op (EXTZ opc) →
  decode_aux (ast.binop op sz (Rm_i r imm)) (b :: l1 ++ l2)
| binop_imm8 (opc r l1 imm l2 op) :
  let sz := op_size rex.is_some rex.W tt in
  read_opcode_ModRM rex opc r l1 →
  binop.bits op (EXTZ opc) →
  read_imm8 imm l2 →
  decode_aux (ast.binop op sz (Rm_i r imm)) (0x83 :: l1 ++ l2)
| test (b : byte) (v reg r l) :
  split_bits b.to_nat [⟨1, S v⟩, ⟨7, 0b1000010⟩] →
  let sz := op_size rex.is_some rex.W v in
  read_ModRM rex reg r l →
  decode_aux (ast.binop binop.tst sz (Rm_r r reg)) (b :: l)
| xchg (b : byte) (v reg r l) :
  split_bits b.to_nat [⟨1, S v⟩, ⟨7, 0b1000011⟩] →
  let sz := op_size rex.is_some rex.W v in
  read_ModRM rex reg r l →
  decode_aux (ast.xchg sz r reg) (b :: l)
| mov (b : byte) (v d reg r l) :
  split_bits b.to_nat [⟨1, S v⟩, ⟨1, S d⟩, ⟨6, 0b100010⟩] →
  let sz := op_size rex.is_some rex.W v in
  read_ModRM rex reg r l →
  let src_dst := if d then R_rm reg r else Rm_r r reg in
  decode_aux (ast.mov sz src_dst) (b :: l)
| lea (reg r l) :
  let sz := op_size tt rex.W tt in
  read_ModRM rex reg r l → RM.is_mem r →
  decode_aux (ast.lea sz (R_rm reg r)) (0x8d :: l)
| pop_rm (r l) :
  read_opcode_ModRM rex 0 r l →
  decode_aux (ast.pop r) (0x8f :: l)
| xchg_rax (b : byte) (r) :
  split_bits b.to_nat [⟨3, r⟩, ⟨5, 0b10010⟩] →
  let sz := op_size tt rex.W tt in
  decode_aux (ast.xchg sz (RM.reg RAX) (rex_reg rex.B r)) [b]
| test_rax (b : byte) (v imm l) :
  split_bits b.to_nat [⟨1, S v⟩, ⟨7, 0b1010100⟩] →
  let sz := op_size tt rex.W v in
  read_imm sz imm l →
  decode_aux (ast.binop binop.tst sz (Rm_i (RM.reg RAX) imm)) (b :: l)
| mov64 (b : byte) (r v imm l) :
  split_bits b.to_nat [⟨3, r⟩, ⟨1, S v⟩, ⟨4, 0xb⟩] →
  let sz := op_size rex.is_some rex.W v in
  read_full_imm sz imm l →
  decode_aux (ast.mov sz (Rm_i (RM.reg (rex_reg rex.B r)) imm)) (b :: l)
| binop_hi (b : byte) (v opc r imm op l1 l2) :
  split_bits b.to_nat [⟨1, S v⟩, ⟨7, 0b1100000⟩] →
  let sz := op_size rex.is_some rex.W v in
  read_opcode_ModRM rex opc r l1 → opc ≠ 6 →
  binop.bits op (rex_reg tt opc) →
  read_imm8 imm l2 →
  decode_aux (ast.binop op sz (Rm_i (RM.reg (rex_reg tt opc)) imm)) (b :: l1 ++ l2)
| ret (b : byte) (v imm l) :
  split_bits b.to_nat [⟨1, S v⟩, ⟨7, 0b1100001⟩] →
  (if v then imm = 0 ∧ l = [] else read_imm16 imm l) →
  decode_aux (ast.ret imm) (b :: l)
| mov_imm (b : byte) (v opc r imm l1 l2) :
  split_bits b.to_nat [⟨1, S v⟩, ⟨7, 0b1100011⟩] →
  let sz := op_size rex.is_some rex.W v in
  read_opcode_ModRM rex opc r l1 →
  read_imm sz imm l2 →
  decode_aux (ast.mov sz (Rm_i r imm)) (b :: l1 ++ l2)
| leave : decode_aux ast.leave [0xc9]
| int (imm) : decode_aux (ast.int imm) [0xcd, imm]
| binop_hi_reg (b : byte) (v x opc r op l) :
  split_bits b.to_nat [⟨1, S v⟩, ⟨1, S x⟩, ⟨6, 0b110100⟩] →
  let sz := op_size rex.is_some rex.W v in
  read_opcode_ModRM rex opc r l → opc ≠ 6 →
  binop.bits op (rex_reg tt opc) →
  decode_aux (ast.binop op sz (if x then Rm_r r RCX else Rm_i r 1)) (b :: l)
| loopcc (b : byte) (x imm l) :
  split_bits b.to_nat [⟨1, S x⟩, ⟨7, 0b1110000⟩] →
  read_imm8 imm l →
  decode_aux (ast.loop (cond_code.mk (bnot x) basic_cond.e) imm) (b :: l)
| loop (imm l) :
  read_imm8 imm l →
  decode_aux (ast.loop cond_code.always imm) (0xe2 :: l)
| call (imm l) :
  read_imm32 imm l →
  decode_aux (ast.call (imm_rm.imm imm)) (0xe8 :: l)
| jump (b : byte) (x imm l) :
  split_bits b.to_nat [⟨1, 0b1⟩, ⟨1, S x⟩, ⟨6, 0b111010⟩] →
  (if x then read_imm8 imm l else read_imm32 imm l) →
  decode_aux (ast.jcc cond_code.always imm) (b :: l)
| cmc : decode_aux ast.cmc [0xf5]
| clc : decode_aux ast.clc [0xf8]
| stc : decode_aux ast.stc [0xf9]
| F (b : byte) (v x opc r a l1 l2) :
  split_bits b.to_nat [⟨1, S v⟩, ⟨2, 0b11⟩, ⟨1, S x⟩, ⟨7, 0xf⟩] →
  let sz := op_size rex.is_some rex.W v in
  read_opcode_ModRM rex opc r l1 →
  decode_misc1 v sz r x opc a l2 →
  decode_aux a (b :: l1 ++ l2)

inductive decode : ast → list byte → Prop
| mk {rex l1 a l2} :
  read_prefixes rex l1 → decode_aux rex a l2 → decode a (l1 ++ l2)

----------------------------------------
-- Dynamic semantics
----------------------------------------

structure flags := (CF ZF SF OF : bool)

def basic_cond.read : basic_cond → flags → bool
| basic_cond.o f := f.OF
| basic_cond.b f := f.CF
| basic_cond.e f := f.ZF
| basic_cond.na f := f.CF || f.ZF
| basic_cond.s f := f.SF
| basic_cond.l f := f.SF ≠ f.OF
| basic_cond.ng f := f.ZF || (f.SF ≠ f.OF)

def cond_code.read : cond_code → flags → bool
| cond_code.always f := tt
| (cond_code.pos c) f := c.read f
| (cond_code.neg c) f := bnot $ c.read f

structure mem :=
(valid : qword → Prop)
(ro : qword → Prop)
(mem : ∀ w, valid w → byte)

structure config :=
(rip : qword)
(regs : regnum → qword)
(flags : flags)
(mem : mem)

def mem.read1 (m : mem) (w : qword) (b : byte) : Prop := ∃ h, b = m.mem w h

inductive mem.read (m : mem) : qword → list byte → Prop
| nil (w) : mem.read w []
| cons {w b l} : m.read1 w b → mem.read (w + 1) l → mem.read w (b :: l)

def mem.set (m : mem) (w : qword) (b : byte) : mem :=
{mem := λ w' h', if w = w' then b else m.mem w' h', ..m}

inductive mem.write1 (m : mem) (w : qword) (b : byte) : mem → Prop
| mk (h : m.valid w) : ¬ m.ro w → mem.write1 (m.set w b)

inductive mem.write : mem → qword → list byte → mem → Prop
| nil (m w) : mem.write m w [] m
| cons {m1 m2 m3 : mem} {w b l} :
  m1.write1 w b m2 → mem.write m2 (w + 1) l m3 → mem.write m1 w (b :: l) m3

inductive EA
| Ea_i : qword → EA
| Ea_r : regnum → EA
| Ea_m : qword → EA
open EA

def index_ea (k : config) : option scale_index → qword
| none := 0
| (some ⟨sc, ix⟩) := (bitvec.shl 1 sc.to_nat) * (k.regs ix)

def base.ea (k : config) : base → qword
| base.none := 0
| base.rip := k.rip
| (base.reg n) := k.regs n

def RM.ea (k : config) : RM → EA
| (RM.reg n) := Ea_r n
| (RM.mem ix b d) := Ea_m (index_ea k ix + b.ea k + d)

def ea_dest (k : config) : dest_src → EA
| (Rm_i v _) := v.ea k
| (Rm_r v _) := v.ea k
| (R_rm v _) := Ea_r v

def ea_src (k : config) : dest_src → EA
| (Rm_i _ v) := Ea_i v
| (Rm_r _ v) := Ea_r v
| (R_rm _ v) := v.ea k

def imm_rm.ea (k : config) : imm_rm → EA
| (imm_rm.rm v) := v.ea k
| (imm_rm.imm v) := Ea_i v

def EA.read (k : config) : EA → ∀ sz : wsize, bitvec sz.to_nat → Prop
| (Ea_i i) sz b := b = EXTZ i
| (Ea_r r) (Sz8 ff) b := b = EXTZ
  (if ¬ r.nth 2 then k.regs r else (k.regs (r.and 4)).shl 8)
| (Ea_r r) sz b := b = EXTZ (k.regs r)
| (Ea_m a) sz b := ∃ l, k.mem.read a l ∧ bits_to_byte (sz.to_nat / 8) b l

def EA.readq (k : config) (ea : EA) (sz : wsize) (q : qword) : Prop :=
∃ w, ea.read k sz w ∧ q = EXTZ w

def EA.read' (ea : EA) (sz : wsize) : pstate config qword :=
pstate.assert $ λ k, ea.readq k sz

def config.set_reg (k : config) (r : regnum) (v : qword) : config :=
{regs := λ i, if i = r then v else k.regs i, ..k}

def config.write_reg (k : config) (r : regnum) : ∀ sz : wsize, bitvec sz.to_nat → config → Prop
| (Sz8 have_rex) v k' :=
  if ¬ have_rex ∧ r.nth 2 then
    let r' := r.and 4 in
    k' = config.set_reg k r' ((k.regs r').update 8 v)
  else
    k' = config.set_reg k r ((k.regs r).update 0 v)
| Sz16 v k' := k' = config.set_reg k r ((k.regs r).update 0 v)
| Sz32 v k' := k' = config.set_reg k r (EXTZ v)
| Sz64 v k' := k' = config.set_reg k r v

inductive EA.write (k : config) : EA → ∀ sz : wsize, bitvec sz.to_nat → config → Prop
| Ea_r (r sz v k') : config.write_reg k r sz v k' → EA.write (Ea_r r) sz v k'
| Ea_m (a) (sz : wsize) (v l m') :
  let n := sz.to_nat / 8 in
  bits_to_byte n v l → k.mem.write a l m' →
  EA.write (Ea_m a) sz v {mem := m', ..k}

def EA.writeq (k : config) (ea : EA) (sz : wsize) (q : qword) (k' : config) : Prop :=
ea.write k sz (EXTZ q) k'

def EA.write' (ea : EA) (sz : wsize) (q : qword) : pstate config unit :=
pstate.lift $ λ k _, EA.writeq k ea sz q

def write_rip (q : qword) : pstate config unit :=
pstate.modify $ λ k, {rip := q, ..k}

inductive dest_src.read (k : config) (sz : wsize) (ds : dest_src) : EA → qword → qword → Prop
| mk (d s) : let ea := ea_dest k ds in
  ea.readq k sz d → (ea_src k ds).readq k sz s → dest_src.read ea d s

def EA.call_dest (k : config) : EA → qword → Prop
| (Ea_i i) q := q = k.rip + i
| (Ea_r r) q := q = k.regs r
| (Ea_m a) q := (Ea_m a).read k Sz64 q

inductive EA.jump (k : config) : EA → config → Prop
| mk (ea : EA) (q) : ea.call_dest k q → EA.jump ea {rip := q, ..k}

def write_flags (f : config → flags → flags) : pstate config unit :=
pstate.lift $ λ k _ k', k' = {flags := f k k.flags, ..k}

def MSB (sz : wsize) (w : qword) : bool := w.nth (fin.of_nat (sz.to_nat - 1))

def write_SF (sz : wsize) (w : qword) : pstate config unit :=
write_flags $ λ k f, {SF := MSB sz w, ..f}

def write_ZF (sz : wsize) (w : qword) : pstate config unit :=
write_flags $ λ k f, {ZF := (EXTZ w : bitvec sz.to_nat) = 0, ..f}

def write_SF_ZF (sz : wsize) (w : qword) : pstate config unit :=
write_SF sz w >> write_ZF sz w

def write_arith_flags (sz : wsize) (w : qword) (c o : bool) : pstate config unit :=
write_flags (λ k f, {CF := c, OF := o, ..f}) >>
write_SF_ZF sz w

def write_logical_flags (sz : wsize) (w : qword) : pstate config unit :=
write_arith_flags sz w ff ff

def erase_flags : pstate config unit :=
do f ← pstate.any, pstate.modify $ λ s, {flags := f, ..s}

def sadd_OV (sz : wsize) (a b : qword) : bool :=
MSB sz a = MSB sz b ∧ MSB sz (a + b) ≠ MSB sz a

def ssub_OV (sz : wsize) (a b : qword) : bool :=
MSB sz a ≠ MSB sz b ∧ MSB sz (a - b) ≠ MSB sz a

def add_carry (sz : wsize) (a b : qword) : qword × bool × bool :=
(a + b, 2 ^ sz.to_nat ≤ a.to_nat + b.to_nat, sadd_OV sz a b)

def sub_borrow (sz : wsize) (a b : qword) : qword × bool × bool :=
(a - b, a.to_nat < b.to_nat, ssub_OV sz a b)

def write_arith_result (sz : wsize) (w : qword) (c o : bool) (ea : EA) : pstate config unit :=
write_arith_flags sz w c o >> ea.write' sz w

def write_SF_ZF_result (sz : wsize) (w : qword) (ea : EA) : pstate config unit :=
write_SF_ZF sz w >> ea.write' sz w

def mask_shift : wsize → qword → ℕ
| Sz64 w := (EXTZ w : bitvec 6).to_nat
| _    w := (EXTZ w : bitvec 5).to_nat

def write_binop (sz : wsize) (a b : qword) (ea : EA) : binop → pstate config unit
| binop.add := let (w, c, o) := add_carry sz a b in write_arith_result sz w c o ea
| binop.sub := let (w, c, o) := sub_borrow sz a b in write_arith_result sz w c o ea
| binop.cmp := let (w, c, o) := sub_borrow sz a b in write_arith_flags sz w c o
| binop.tst := write_logical_flags sz (a.and b)
| binop.and := write_SF_ZF_result sz (a.and b) ea -- TODO: double check flags
| binop.xor := write_SF_ZF_result sz (a.xor b) ea
| binop.or  := write_SF_ZF_result sz (a.or b) ea
| binop.rol := pstate.fail
| binop.ror := pstate.fail
| binop.rcl := pstate.fail
| binop.rcr := pstate.fail
| binop.shl := ea.write' sz (a.shl (mask_shift sz b)) >> erase_flags
| binop.shr := ea.write' sz (a.ushr (mask_shift sz b)) >> erase_flags
| binop.sar := ea.write' sz (a.fill_shr (mask_shift sz b) (MSB sz a)) >> erase_flags
| binop.adc := do
  k ← pstate.get,
  let result := a + b + EXTZ (S k.flags.CF),
  let CF := 2 ^ sz.to_nat ≤ a.to_nat + b.to_nat,
  OF ← pstate.any,
  write_arith_result sz result CF OF ea
| binop.sbb := do
  k ← pstate.get,
  let carry : qword := EXTZ (S k.flags.CF),
  let result := a - (b + carry),
  let CF := a.to_nat < b.to_nat + carry.to_nat,
  OF ← pstate.any,
  write_arith_result sz result CF OF ea

def write_unop (sz : wsize) (a : qword) (ea : EA) : unop → pstate config unit
| unop.inc := do
  let (w, _, o) := add_carry sz a 1,
  write_flags (λ k f, {OF := o, ..f}),
  write_SF_ZF_result sz w ea
| unop.dec := do
  let (w, _, o) := sub_borrow sz a 1,
  write_flags (λ k f, {OF := o, ..f}),
  write_SF_ZF_result sz w ea
| unop.not := ea.write' sz a.not
| unop.neg := do
  CF ← pstate.any,
  write_flags (λ k f, {CF := CF, ..f}),
  write_SF_ZF_result sz (-a) ea

def pop_aux : pstate config qword :=
do k ← pstate.get,
  let sp := k.regs RSP,
  (Ea_r RSP).write' Sz64 (sp + 8),
  (Ea_m sp).read' Sz64

def pop (rm : RM) : pstate config unit :=
do k ← pstate.get, pop_aux >>= (rm.ea k).write' Sz64

def pop_rip (rm : RM) : pstate config unit := pop_aux >>= write_rip

def push_aux (w : qword) : pstate config unit :=
do k ← pstate.get,
  let sp := k.regs RSP - 8,
  (Ea_r RSP).write' Sz64 sp,
  (Ea_m sp).write' Sz64 w

def push (i : imm_rm) (w : qword) : pstate config unit :=
do k ← pstate.get, (i.ea k).read' Sz64 >>= push_aux

def push_rip (i : imm_rm) (w : qword) : pstate config unit :=
do k ← pstate.get, push_aux k.rip

end x86