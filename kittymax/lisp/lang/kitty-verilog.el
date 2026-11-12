;;; kitty-verilog.el --- Verilog and SystemVerilog  -*- lexical-binding: t; -*-

;;; Commentary:

;; verilog-mode (Wilson Snyder's, from GNU ELPA: it handles .v, .sv, .svh) with
;; its AUTO macros, verible as the language server (syntax, style, formatting),
;; and a flymake backend that runs verilator --lint-only on the buffer as you
;; type, for the checks a language server does not do: widths, unused and
;; undriven signals, latches.  iverilog + vvp simulate a testbench from SPC m,
;; gtkwave opens the waves.

;;; Code:

(require 'kitty-lib)
(require 'subr-x)

(defvar flymake-diagnostic-functions)
(declare-function flymake-diag-region "flymake")
(declare-function flymake-make-diagnostic "flymake")

(setq verilog-indent-level 2
      verilog-indent-level-module 2
      verilog-indent-level-declaration 2
      verilog-indent-level-behavioral 2
      verilog-indent-level-directive 1
      verilog-case-indent 2
      verilog-cexp-indent 2
      verilog-auto-newline nil
      verilog-auto-endcomments t
      verilog-tab-always-indent t
      verilog-align-ifelse nil
      verilog-minimum-comment-distance 20
      verilog-linter "verilator --lint-only -Wall"
      verilog-simulator "iverilog -g2012"
      verilog-compiler "iverilog -g2012")

(add-to-list 'auto-mode-alist '("\\.\\(sv\\|svh\\|vh\\|v\\)\\'" . verilog-mode))

;;;; verilator as a flymake backend

(defconst kitty--verilator-regexp
  "^%\\(Error\\|Warning\\)\\(?:-[A-Z0-9_]+\\)?: \\(.+?\\):\\([0-9]+\\):\\(?:\\([0-9]+\\):\\)? \\(.*\\)$"
  "A verilator message: severity, file, line, optional column, text.")

(defvar-local kitty--verilator-process nil)

(defun kitty-verilog-flymake (report-fn &rest _args)
  "Flymake backend: lint the buffer with verilator.  See `flymake-diagnostic-functions'."
  (if (not (executable-find "verilator"))
      (funcall report-fn nil)
    (when (process-live-p kitty--verilator-process)
      (kill-process kitty--verilator-process))
    (let* ((source (current-buffer))
           (dir (expand-file-name (or (and buffer-file-name (file-name-directory buffer-file-name))
                                      default-directory)))
           (ext (if buffer-file-name (file-name-extension buffer-file-name t) ".sv"))
           (tmp (make-temp-file "kitty-lint-" nil ext))
           (tmp-name (file-name-nondirectory tmp)))
      ;; Lint what is in the buffer, not what is on disk.
      (save-restriction
        (widen)
        (write-region (point-min) (point-max) tmp nil 'silent))
      (setq kitty--verilator-process
            (make-process
             :name "verilator-flymake" :noquery t :connection-type 'pipe
             :buffer (generate-new-buffer " *verilator-flymake*")
             :command (list "verilator" "--lint-only" "-Wall" "-Wno-DECLFILENAME"
                            (concat "-I" dir) (concat "-y" dir) tmp)
             :sentinel
             (lambda (proc _event)
               (when (memq (process-status proc) '(exit signal))
                 (unwind-protect
                     (if (with-current-buffer source (eq proc kitty--verilator-process))
                         (let (diags)
                           (with-current-buffer (process-buffer proc)
                             (goto-char (point-min))
                             (while (re-search-forward kitty--verilator-regexp nil t)
                               (let ((severity (match-string 1))
                                     (file (match-string 2))
                                     (line (string-to-number (match-string 3)))
                                     (col (and (match-string 4) (string-to-number (match-string 4))))
                                     (text (match-string 5)))
                                 (when (equal (file-name-nondirectory file) tmp-name)
                                   (let ((region (flymake-diag-region source line col)))
                                     (push (flymake-make-diagnostic
                                            source (car region) (cdr region)
                                            (if (equal severity "Error") :error :warning)
                                            text)
                                           diags))))))
                           (funcall report-fn (nreverse diags)))
                       (flymake-log :warning "Canceling obsolete check %s" proc))
                   (ignore-errors (kill-buffer (process-buffer proc)))
                   (ignore-errors (delete-file tmp))))))))))

(defun kitty--verilog-setup ()
  (add-hook 'flymake-diagnostic-functions #'kitty-verilog-flymake nil t)
  (kitty-eglot-ensure-for "verible-verilog-ls")
  (setq-local indent-tabs-mode nil
              fill-column 100))
(kitty-add-hook 'verilog-mode-hook #'kitty--verilog-setup)

;;;; Lint, simulate, look at waves

(defun kitty-verilog-lint ()
  "Run verilator over this file in a compilation buffer."
  (interactive)
  (compile (concat verilog-linter " "
                   (shell-quote-argument (or buffer-file-name (user-error "Save the buffer first"))))))

(defun kitty-verilog-simulate ()
  "Compile this testbench with iverilog and run it with vvp.
Modules it instantiates are looked up next to it."
  (interactive)
  (let* ((file (or buffer-file-name (user-error "Save the buffer first")))
         (dir (file-name-directory file))
         (out-dir (expand-file-name "verilog/" kitty-cache-dir))
         (out (expand-file-name (concat (file-name-base file) ".vvp") out-dir)))
    (make-directory out-dir t)
    (save-buffer)
    (let ((default-directory dir))
      (compile (format "%s -Wall -y %s -o %s %s && vvp %s"
                       verilog-simulator
                       (shell-quote-argument dir) (shell-quote-argument out)
                       (shell-quote-argument file) (shell-quote-argument out))))))

(defun kitty-verilog-waves ()
  "Open a .vcd file from this directory in gtkwave."
  (interactive)
  (let ((vcd (read-file-name "Waves: " default-directory nil t nil
                             (lambda (f) (or (file-directory-p f) (string-match-p "\\.\\(vcd\\|fst\\)\\'" f))))))
    (start-process "gtkwave" nil "gtkwave" vcd)))

(dolist (mode '(verilog-mode verilog-ts-mode))
  ;; my-nvim's <leader>m keys (ftplugin/verilog.lua): mm lint, mr run, mw waves.
  (kitty-local-leader mode
    "m" '("lint (verilator)" . kitty-verilog-lint)
    "r" '("run (iverilog + vvp)" . kitty-verilog-simulate)
    "w" '("waves" . kitty-verilog-waves)
    "a" '("AUTO expand" . verilog-auto)
    "A" '("AUTO delete" . verilog-delete-auto)
    "j" '("AUTO inject" . verilog-inject-auto)
    "f" '("format" . kitty-format)
    "d" '("jump to module" . verilog-goto-defun)
    "i" (cons "insert" (kitty-keymap
                        "m" '("module" . verilog-sk-module)
                        "a" '("always" . verilog-sk-always)
                        "i" '("initial" . verilog-sk-initial)
                        "c" '("case" . verilog-sk-case)
                        "f" '("for" . verilog-sk-for)
                        "I" '("if" . verilog-sk-if)
                        "F" '("function" . verilog-sk-function)
                        "t" '("task" . verilog-sk-task)
                        "g" '("generate" . verilog-sk-generate)
                        "s" '("state machine" . verilog-sk-state-machine)
                        "u" '("UVM component" . verilog-sk-uvm-component)))))

(provide 'kitty-verilog)
;;; kitty-verilog.el ends here
