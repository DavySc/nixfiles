;;; kitty-verilog-test.el --- tests for the verilator flymake backend  -*- lexical-binding: t; -*-

(require 'ert)
(require 'flymake)
(defvar kitty-cache-dir (make-temp-file "kitty-cache" t))
(defvar kitty-config-dir default-directory)
(require 'kitty-lib)
(require 'kitty-verilog)

(defun kitty-test--fake-verilator (body)
  "A `verilator' executable on `exec-path' that runs shell BODY (the last arg is $last)."
  (let* ((dir (make-temp-file "fakebin" t))
         (exe (expand-file-name "verilator" dir)))
    (with-temp-file exe
      (insert "#!/bin/sh\nfor a in \"$@\"; do last=$a; done\n" body "\n"))
    (set-file-modes exe #o755)
    dir))

(defun kitty-test--lint (text body)
  (let* ((bin (kitty-test--fake-verilator body))
         (exec-path (cons bin exec-path))
         (process-environment (cons (concat "PATH=" bin ":" (getenv "PATH")) process-environment))
         (file (expand-file-name "t.sv" (make-temp-file "sv" t)))
         result)
    (with-temp-buffer
      (insert text)
      (setq buffer-file-name file)
      (set-buffer-modified-p nil)
      (kitty-verilog-flymake (lambda (diags &rest _) (setq result (or diags 'none))))
      (let ((n 0))
        (while (and (null result) (< n 50))
          (accept-process-output nil 0.1)
          (cl-incf n)))
      (set-buffer-modified-p nil))
    result))

(ert-deftest kitty-verilog-flymake-parses-errors-and-warnings ()
  (let ((diags (kitty-test--lint
                "module m;\n  wire [3:0] a;\n  assign a = 1;\nendmodule\n"
                "echo \"%Warning-WIDTH: $last:3:14: Operator ASSIGNW expects 4 bits\"
echo \"                    : ... note: In instance 'm'\"
echo \"%Error: $last:4:1: syntax error, unexpected endmodule\"
exit 1")))
    (should (= 2 (length diags)))
    (should (eq :warning (flymake-diagnostic-type (nth 0 diags))))
    (should (eq :error (flymake-diagnostic-type (nth 1 diags))))
    (should (string-match-p "expects 4 bits" (flymake-diagnostic-text (nth 0 diags))))))

(ert-deftest kitty-verilog-flymake-ignores-other-files ()
  (let ((diags (kitty-test--lint
                "module m; endmodule\n"
                "echo \"%Error: /somewhere/else.sv:1:1: not ours\"
exit 1")))
    (should (eq 'none diags))))

(ert-deftest kitty-verilog-flymake-clean ()
  (should (eq 'none (kitty-test--lint "module m; endmodule\n" "exit 0"))))

(ert-deftest kitty-verilog-flymake-without-verilator-reports-nothing ()
  (let ((exec-path nil) (process-environment (cons "PATH=/nonexistent" process-environment)) result)
    (with-temp-buffer
      (kitty-verilog-flymake (lambda (d &rest _) (setq result (list d)))))
    (should (equal result '(nil)))))

;;; kitty-verilog-test.el ends here
