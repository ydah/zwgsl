# Grammar Summary

This page is a compact summary of the implemented zwgsl surface grammar. It is
not a complete formal specification; when behavior questions need examples and
target-specific notes, prefer the [Language Reference](language.md),
[Builtins](builtins.md), and [Gotchas](gotchas.md).

## Layout

zwgsl source is tokenized before parsing, then the layout resolver inserts
statement separators and block indentation tokens from newlines and indentation.
Most grammar forms below use line breaks, but semantically the parser consumes
resolved statement separators between declarations and statements.

Blocks use `do` / `end` or declaration-specific `end` forms:

```ruby
vertex do
  def main
    gl_Position = vec4(0.0, 0.0, 0.0, 1.0)
  end
end
```

## Top-Level Items

```ebnf
program        ::= top_item*

top_item       ::= version_decl
                 | precision_decl
                 | uniform_decl
                 | struct_def
                 | type_def
                 | trait_def
                 | impl_def
                 | function_def
                 | shader_block

version_decl   ::= "version" string_literal
precision_decl ::= "precision" symbol "," symbol
uniform_decl   ::= "uniform" symbol "," type_spec
```

`version` and `precision` primarily affect GLSL ES output. Uniform declarations
are global and visible to helper functions and shader stages.

Identifiers beginning with `_zwgsl` are reserved for compiler-generated WGSL
helpers and wrappers. The semantic pass warns when source declarations use that
prefix.

## Types

```ebnf
type_spec      ::= identifier type_args?
type_args      ::= "(" type_arg ("," type_arg)* ")"
type_arg       ::= identifier | integer_literal | type_spec
```

The parser accepts nested type applications such as `Vec(N)` and `Mat(4, 4)`.
Semantic checks decide whether a type is a known builtin, user-defined type, or
generic parameter.

## Structs And ADTs

```ebnf
struct_def     ::= "struct" identifier type_params? struct_field* "end"
type_params    ::= "(" identifier ("," identifier)* ")"
struct_field   ::= identifier ":" type_spec

type_def       ::= "type" identifier type_params? variant* "end"
variant        ::= identifier variant_fields?
variant_fields ::= "(" variant_field ("," variant_field)* ")"
variant_field  ::= identifier ":" type_spec
```

Constructors from `type` declarations are values that can be used in expressions
and pattern matching.

## Functions, Traits, And Impls

```ebnf
function_def   ::= "def" identifier params? return_type? type_constraints?
                   stmt* where_clause? "end"
params         ::= "(" param ("," param)* ")"
param          ::= "inout"? identifier ":" type_spec
return_type    ::= "->" type_spec

type_constraints ::= "where" type_constraint ("," type_constraint)*
type_constraint  ::= identifier ":" identifier

where_clause   ::= "where" where_binding*
where_binding  ::= identifier type_annotation? "=" expr
type_annotation ::= ":" type_spec

trait_def      ::= "trait" identifier trait_method* "end"
trait_method   ::= "def" identifier params? return_type? type_constraints? "end"

impl_def       ::= "impl" identifier "for" type_spec function_def* "end"
```

Function bodies return the final expression implicitly when a return type is
declared. Trait methods are declarations; implementations provide regular
function bodies.

## Shader Blocks

```ebnf
shader_block   ::= stage "do" stage_item* "end"
stage          ::= "vertex" | "fragment" | "compute"

stage_item     ::= io_decl
                 | precision_decl
                 | function_def

io_decl        ::= io_kind symbol "," type_spec io_option*
io_kind        ::= "input" | "output" | "varying"
io_option      ::= "," "location" ":" integer_literal
```

`input`, `output`, and `varying` declarations are checked against the active
stage. Compute stages reject render-stage IO declarations.

## Statements

```ebnf
stmt           ::= base_stmt postfix_condition?
base_stmt      ::= let_stmt
                 | if_stmt
                 | unless_stmt
                 | return_stmt
                 | discard_stmt
                 | typed_assignment
                 | assignment
                 | loop_stmt
                 | expr_stmt
postfix_condition ::= ("if" | "unless") expr

let_stmt       ::= "let" binding
binding        ::= identifier type_annotation? "=" expr
typed_assignment ::= identifier ":" type_spec "=" expr
assignment     ::= expr assign_op expr
assign_op      ::= "=" | "+=" | "-=" | "*=" | "/="

return_stmt    ::= "return" expr?
discard_stmt   ::= "discard"
expr_stmt      ::= expr
```

Postfix conditionals wrap a parsed base statement:

```ebnf
postfix_conditional ::= base_stmt ("if" | "unless") expr
```

Block conditionals use Ruby-style branches:

```ebnf
if_stmt        ::= "if" expr stmt* elsif_branch* else_branch? "end"
unless_stmt    ::= "unless" expr stmt* elsif_branch* else_branch? "end"
elsif_branch   ::= "elsif" expr stmt*
else_branch    ::= "else" stmt*
```

Loop statements are method-style forms over expressions:

```ebnf
loop_stmt      ::= expr "." ("times" | "each") "do" loop_binding? stmt* "end"
loop_binding   ::= "|" identifier "|"
```

## Expressions

```ebnf
expr           ::= prefix_expr postfix_expr* binary_tail*
postfix_expr   ::= "." identifier
                 | "(" arguments? ")"
                 | "[" expr "]"
arguments      ::= expr ("," expr)*

prefix_expr    ::= integer_literal
                 | float_literal
                 | string_literal
                 | symbol
                 | identifier
                 | "true"
                 | "false"
                 | "self"
                 | "-" expr
                 | "!" expr
                 | "(" expr ")"
                 | lambda_expr
                 | match_expr

lambda_expr    ::= "|" lambda_params? "|" expr
lambda_params  ::= identifier ("," identifier)*
```

Binary operators are parsed by precedence, from lowest to highest:

| Level | Operators |
| --- | --- |
| 1 | `||` |
| 2 | `&&` |
| 3 | `==`, `!=` |
| 4 | `<`, `>`, `<=`, `>=` |
| 5 | `+`, `-` |
| 6 | `*`, `/`, `%` |
| 7 | unary `-`, unary `!` |
| 8 | member access, calls, indexing |

## Match Expressions

```ebnf
match_expr     ::= "match" expr match_arm* "end"
match_arm      ::= "when" pattern guard? stmt*
guard          ::= "if" expr

pattern        ::= symbol
                 | integer_literal
                 | float_literal
                 | "true"
                 | "false"
                 | "_"
                 | binding_pattern
                 | constructor_pattern
binding_pattern ::= LowerIdentifier
constructor_pattern ::= UpperIdentifier pattern_args?
pattern_args   ::= "(" pattern ("," pattern)* ")"
```

Identifiers that start with an uppercase letter are parsed as constructor
patterns. Lowercase identifiers bind values, and `_` is the wildcard pattern.

## Target Notes

- WGSL is the primary target and supports render and compute stages.
- GLSL ES 3.0 output supports render stages; compute shaders are rejected.
- Builtin type and function availability is documented in
  [Builtins](builtins.md).
- Stage interface, type, trait, and target compatibility rules are semantic
  checks layered on top of this grammar.
