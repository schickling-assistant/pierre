(module
  (import "../common.wat")

  ;; Compare only complete words; length guards keep loads inside the token.
  (func $kdlWord (param $p i32) (param $rhs i32) (result i32)
    (local $len i32)
    (local.set $len (i32.sub (local.get $rhs) (local.get $p)))
    (if (i32.eq (local.get $len) (i32.const 4))
      (then
        (if (i32.eq (i32.load (local.get $p)) (i32.const "true"))
          (then (return (enum.get $Token.boolean))))
        (if (i32.or
              (i32.eq (i32.load (local.get $p)) (i32.const "null"))
              (i32.eq (i32.load (local.get $p)) (i32.const "-inf")))
          (then (return (enum.get $Token.constant.builtin))))))
    (if (i32.eq (local.get $len) (i32.const 5))
      (then
        (if (i32.and
              (i32.eq (i32.load (local.get $p)) (i32.const "fals"))
              (i32.eq (i32.load8_u offset=4 (local.get $p)) (i32.const "e")))
          (then (return (enum.get $Token.boolean))))))
    (if (i32.eq (local.get $len) (i32.const 3))
      (then
        (if (i32.or
              (i32.and (i32.eq (i32.load16_u (local.get $p)) (i32.const "in")) (i32.eq (i32.load8_u offset=2 (local.get $p)) (i32.const "f")))
              (i32.and (i32.eq (i32.load16_u (local.get $p)) (i32.const "na")) (i32.eq (i32.load8_u offset=2 (local.get $p)) (i32.const "n"))))
          (then (return (enum.get $Token.constant.builtin))))))
    (enum.get $Token.string))

  ;; KDL identifiers end at whitespace or structural punctuation, not at the
  ;; ASCII identifier boundary: names may contain hyphens and Unicode.
  (func $kdlBoundary (param $c i32) (result i32)
    (i32.or
      (i32.le_u (local.get $c) (i32.const 32))
      (i32.or
        (i32.or (i32.eq (local.get $c) (i32.const "{")) (i32.eq (local.get $c) (i32.const "}")))
        (i32.or
          (i32.or (i32.eq (local.get $c) (i32.const "(")) (i32.eq (local.get $c) (i32.const ")")))
          (i32.or
            (i32.or (i32.eq (local.get $c) (i32.const ";")) (i32.eq (local.get $c) (i32.const "=")))
            (i32.or (i32.eq (local.get $c) (i32.const 34)) (i32.eq (local.get $c) (i32.const "/"))))))))

  ;; Look ahead without consuming a separator. Newlines are node terminators.
  (func $kdlAfterSpace (param $p i32) (result i32)
    (block $done
      (loop $space
        (br_if $done (i32.ge_u (local.get $p) (global.get $end)))
        (br_if $done
          (i32.eqz (i32.or
            (i32.eq (i32.load8_u (local.get $p)) (i32.const 32))
            (i32.eq (i32.load8_u (local.get $p)) (i32.const 9)))))
        (local.set $p (i32.add (local.get $p) (i32.const 1)))
        (br $space)))
    (local.get $p))

  ;; Return the end of a matching single/triple quote plus raw-string hashes,
  ;; or zero. Every lookahead is bounded by the current embedded scan range.
  (func $kdlStringEnd (param $p i32) (param $quotes i32) (param $hashes i32) (result i32)
    (local $i i32)
    (if (i32.gt_u (i32.add (local.get $p) (i32.add (local.get $quotes) (local.get $hashes))) (global.get $end))
      (then (return (i32.const 0))))
    (loop $quote
      (if (i32.ne (i32.load8_u (i32.add (local.get $p) (local.get $i))) (i32.const 34))
        (then (return (i32.const 0))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $quote (i32.lt_u (local.get $i) (local.get $quotes))))
    (local.set $p (i32.add (local.get $p) (local.get $quotes)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $hash
        (br_if $done (i32.ge_u (local.get $i) (local.get $hashes)))
        (if (i32.ne (i32.load8_u (i32.add (local.get $p) (local.get $i))) (i32.const "#"))
          (then (return (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $hash)))
    (i32.add (local.get $p) (local.get $hashes)))

  ;; Find a string's end, honoring escapes only in non-raw strings. The same
  ;; scanner is used for name lookahead and for resumable string bodies.
  (func $kdlStringScan (param $p i32) (param $quotes i32) (param $hashes i32) (param $raw i32) (result i32)
    (local $close i32)
    (block $done
      (loop $body
        (br_if $done (i32.ge_u (local.get $p) (global.get $end)))
        (if (i32.eq (i32.load8_u (local.get $p)) (i32.const 34))
          (then
            (local.set $close (call $kdlStringEnd (local.get $p) (local.get $quotes) (local.get $hashes)))
            (if (local.get $close) (then (return (local.get $close))))))
        (if (i32.and (i32.eqz (local.get $raw)) (i32.eq (i32.load8_u (local.get $p)) (i32.const 92)))
          (then
            (local.set $p (i32.add (local.get $p) (i32.const 1)))
            (br_if $done (i32.ge_u (local.get $p) (global.get $end)))))
        (local.set $p (i32.add (local.get $p) (i32.const 1)))
        (br $body)))
    (i32.const 0))

  ;; A lightweight node/entry state machine is enough to distinguish names
  ;; from values. Slashdash uses the same scanner, but colors the next complete
  ;; node, argument, property, or child block as a comment. Its brace depth is
  ;; independent of ordinary node context so nested children cannot end it.
  (func $hlKdl
    (local $c i32)
    (local $lhs i32)
    (local $p i32)
    (local $close i32)
    (local $tok i32)
    (local $inNode i32)
    (local $inType i32)
    (local $continued i32)
    (local $quotes i32)
    (local $hashes i32)
    (local $raw i32)
    (local $stringTok i32)
    (local $mute i32) ;; 1 pending node, 2 node, 3 entry, 4 key, 5 value, 6 block
    (local $muteDepth i32)
    (call $lexEmitLeadingContinuation)
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (global.get $ptr) (global.get $end)))
        (local.set $lhs (global.get $ptr))
        (local.set $c (i32.load8_u (global.get $ptr)))
        (block $atom
          (if (local.get $quotes)
            (then
              (local.set $tok (local.get $stringTok))
              (local.set $close (call $kdlStringScan (global.get $ptr) (local.get $quotes) (local.get $hashes) (local.get $raw)))
              (global.set $ptr (select (local.get $close) (global.get $end) (local.get $close)))
              (if (local.get $close) (then (local.set $quotes (i32.const 0))))
              (br $atom)))

          (if (i32.le_u (local.get $c) (i32.const 32))
            (then
              (global.set $ptr (i32.add (global.get $ptr) (i32.const 1)))
              (if (i32.or (i32.eq (local.get $c) (i32.const 10)) (i32.eq (local.get $c) (i32.const 13)))
                (then
                  (if (i32.eqz (local.get $continued))
                    (then
                      (local.set $inNode (i32.const 0))
                      (if (i32.and (i32.eq (local.get $mute) (i32.const 2)) (i32.eqz (local.get $muteDepth)))
                        (then (local.set $mute (i32.const 0))))))
                  ;; A CRLF is one terminator, including after a continuation.
                  (if (i32.and (i32.eq (local.get $c) (i32.const 13)) (i32.eq (call $templateByte (global.get $ptr)) (i32.const 10)))
                    (then (global.set $ptr (i32.add (global.get $ptr) (i32.const 1)))))
                  (local.set $continued (i32.const 0))))
              (if (local.get $mute)
                (then (call $emitTok (enum.get $Token.comment) (local.get $lhs) (global.get $ptr)))
                (else (call $emitTok (enum.get $Token.none) (local.get $lhs) (global.get $ptr))))
              (br $next)))

          (if (i32.eq (local.get $c) (i32.const "/"))
            (then
              (local.set $p (call $templateByte (i32.add (global.get $ptr) (i32.const 1))))
              (if (i32.eq (local.get $p) (i32.const "/"))
                (then (call $lexLineComment (i32.const 2) (enum.get $Token.comment)) (br $next)))
              (if (i32.eq (local.get $p) (i32.const "*"))
                (then (call $lexNestedBlockComment (i32.const 0x2a2f) (i32.const 0x2f2a) (enum.get $Token.comment)) (br $next)))
              (if (i32.eq (local.get $p) (i32.const "-"))
                (then
                  (if (i32.eqz (local.get $mute))
                    (then (local.set $mute (select (i32.const 3) (i32.const 1) (local.get $inNode)))))
                  (global.set $ptr (i32.add (global.get $ptr) (i32.const 2)))
                  (call $emitTok (enum.get $Token.comment) (local.get $lhs) (global.get $ptr))
                  (br $next)))))

          (if (i32.eq (local.get $c) (i32.const 92))
            (then
              (local.set $continued (i32.const 1))
              (global.set $ptr (i32.add (global.get $ptr) (i32.const 1)))
              (call $emitTok (select (enum.get $Token.comment) (enum.get $Token.punctuation.delimiter) (local.get $mute)) (local.get $lhs) (global.get $ptr))
              (br $next)))

          (if (i32.or (i32.eq (local.get $c) (i32.const "(")) (i32.eq (local.get $c) (i32.const ")")))
            (then
              (local.set $inType (i32.eq (local.get $c) (i32.const "(")))
              (global.set $ptr (i32.add (global.get $ptr) (i32.const 1)))
              (call $emitTok (select (enum.get $Token.comment) (enum.get $Token.punctuation.bracket) (local.get $mute)) (local.get $lhs) (global.get $ptr))
              (br $next)))

          (if (i32.or (i32.eq (local.get $c) (i32.const "{")) (i32.eq (local.get $c) (i32.const "}")))
            (then
              (if (i32.eq (local.get $c) (i32.const "{"))
                (then
                  (if (local.get $mute)
                    (then
                      (local.set $muteDepth (i32.add (local.get $muteDepth) (i32.const 1)))
                      (if (i32.eq (local.get $mute) (i32.const 3)) (then (local.set $mute (i32.const 6))))))
                  (local.set $inNode (i32.const 0)))
                (else (local.set $inNode (i32.const 1))))
              (global.set $ptr (i32.add (global.get $ptr) (i32.const 1)))
              (call $emitTok (select (enum.get $Token.comment) (enum.get $Token.punctuation.bracket) (local.get $mute)) (local.get $lhs) (global.get $ptr))
              (if (i32.and (i32.eq (local.get $c) (i32.const "}")) (i32.ne (local.get $muteDepth) (i32.const 0)))
                (then
                  (local.set $muteDepth (i32.sub (local.get $muteDepth) (i32.const 1)))
                  (if (i32.and (i32.eq (local.get $mute) (i32.const 6)) (i32.eqz (local.get $muteDepth)))
                    (then (local.set $mute (i32.const 0))))))
              (br $next)))

          (if (i32.or (i32.eq (local.get $c) (i32.const ";")) (i32.eq (local.get $c) (i32.const "=")))
            (then
              (global.set $ptr (i32.add (global.get $ptr) (i32.const 1)))
              (call $emitTok (select (enum.get $Token.comment) (enum.get $Token.punctuation.delimiter) (local.get $mute)) (local.get $lhs) (global.get $ptr))
              (if (i32.eq (local.get $c) (i32.const ";"))
                (then
                  (local.set $inNode (i32.const 0))
                  (if (i32.and (i32.eq (local.get $mute) (i32.const 2)) (i32.eqz (local.get $muteDepth))) (then (local.set $mute (i32.const 0)))))
                (else (if (i32.eq (local.get $mute) (i32.const 4)) (then (local.set $mute (i32.const 5))))))
              (br $next)))

          ;; Both KDL 2 hash-prefixed and KDL 1 r-prefixed raw strings.
          (local.set $p (global.get $ptr))
          (local.set $raw (i32.const 0))
          (local.set $hashes (i32.const 0))
          (if (i32.eq (local.get $c) (i32.const "r"))
            (then (local.set $p (i32.add (local.get $p) (i32.const 1))) (local.set $raw (i32.const 1))))
          (block $hashDone
            (loop $hash
              (br_if $hashDone (i32.ne (call $templateByte (local.get $p)) (i32.const "#")))
              (local.set $hashes (i32.add (local.get $hashes) (i32.const 1)))
              (local.set $raw (i32.const 1))
              (local.set $p (i32.add (local.get $p) (i32.const 1)))
              (br $hash)))
          (if (i32.eq (call $templateByte (local.get $p)) (i32.const 34))
            (then
              (local.set $quotes (i32.const 1))
              (if (i32.and
                    (i32.eq (call $templateByte (i32.add (local.get $p) (i32.const 1))) (i32.const 34))
                    (i32.eq (call $templateByte (i32.add (local.get $p) (i32.const 2))) (i32.const 34)))
                (then (local.set $quotes (i32.const 3))))
              (global.set $ptr (i32.add (local.get $p) (local.get $quotes)))
              (local.set $close (call $kdlStringScan (global.get $ptr) (local.get $quotes) (local.get $hashes) (local.get $raw)))
              (local.set $tok (enum.get $Token.string))
              (if (i32.eqz (local.get $inNode)) (then (local.set $tok (enum.get $Token.tag))))
              (if (local.get $close)
                (then
                  (if (i32.eq (call $templateByte (call $kdlAfterSpace (local.get $close))) (i32.const "="))
                    (then (local.set $tok (enum.get $Token.attribute))))))
              (if (local.get $inType) (then (local.set $tok (enum.get $Token.type))))
              (local.set $stringTok (local.get $tok))
              (global.set $ptr (select (local.get $close) (global.get $end) (local.get $close)))
              (if (local.get $close) (then (local.set $quotes (i32.const 0))))
              (br $atom)))

          ;; Bare values include the v2 keywords and the inexpensive v1 forms.
          (global.set $ptr (i32.add (global.get $ptr) (i32.const 1)))
          (block $wordDone
            (loop $word
              (br_if $wordDone (i32.ge_u (global.get $ptr) (global.get $end)))
              (br_if $wordDone (call $kdlBoundary (i32.load8_u (global.get $ptr))))
              (global.set $ptr (i32.add (global.get $ptr) (i32.const 1)))
              (br $word)))
          (local.set $tok (enum.get $Token.string))
          (local.set $p (local.get $lhs))
          (if (i32.eq (local.get $c) (i32.const "#")) (then (local.set $p (i32.add (local.get $p) (i32.const 1)))))
          (local.set $tok (call $kdlWord (local.get $p) (global.get $ptr)))
          (local.set $p (local.get $lhs))
          (if (i32.or (i32.eq (local.get $c) (i32.const "+")) (i32.eq (local.get $c) (i32.const "-")))
            (then (local.set $p (i32.add (local.get $p) (i32.const 1)))))
          (if (i32.le_u (i32.sub (call $templateByte (local.get $p)) (i32.const "0")) (i32.const 9))
            (then (local.set $tok (enum.get $Token.number))))
          (if (i32.eqz (local.get $inNode)) (then (local.set $tok (enum.get $Token.tag))))
          (if (i32.eq (call $templateByte (call $kdlAfterSpace (global.get $ptr))) (i32.const "="))
            (then (local.set $tok (enum.get $Token.attribute))))
          (if (local.get $inType) (then (local.set $tok (enum.get $Token.type)))))

        (call $emitTok (select (enum.get $Token.comment) (local.get $tok) (local.get $mute)) (local.get $lhs) (global.get $ptr))
        (if (i32.eqz (local.get $quotes))
          (then
            (if (i32.eqz (local.get $inType))
              (then
                (local.set $inNode (i32.const 1))
                (if (i32.eq (local.get $mute) (i32.const 1)) (then (local.set $mute (i32.const 2))))
                (if (i32.eq (local.get $mute) (i32.const 3))
                  (then
                    (local.set $mute (select (i32.const 4) (i32.const 0)
                      (i32.eq (call $templateByte (call $kdlAfterSpace (global.get $ptr))) (i32.const "="))))))
                (if (i32.eq (local.get $mute) (i32.const 5)) (then (local.set $mute (i32.const 0))))))))
        (br $next))))
)
