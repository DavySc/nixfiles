;;; kitty-c.el --- C and C++  -*- lexical-binding: t; -*-

;;; Commentary:

;; tree-sitter modes, clangd (indexing in the background, clang-tidy
;; diagnostics), clang-format on save when the project has a .clang-format,
;; CMake/Ninja or Make builds from SPC m, gdb for debugging.

;;; Code:

(require 'kitty-lib)
(require 'subr-x)

(setq c-ts-mode-indent-offset 4
      c-ts-mode-indent-style 'k&r
      c-basic-offset 4
      c-default-style '((c-mode . "k&r") (c++-mode . "stroustrup") (other . "gnu")))

(dolist (hook '(c-mode-hook c-ts-mode-hook c++-mode-hook c++-ts-mode-hook))
  (add-hook hook (lambda () (kitty-eglot-ensure-for "clangd"))))

;; clang-format has an opinion even without a style file; only format when
;; the project pinned one.
(defun kitty--c-format-on-save-p ()
  (and buffer-file-name
       (locate-dominating-file buffer-file-name ".clang-format")))
(defun kitty--c-setup ()
  (unless (kitty--c-format-on-save-p)
    (when (fboundp 'apheleia-mode) (apheleia-mode -1))))
(dolist (hook '(c-mode-hook c-ts-mode-hook c++-mode-hook c++-ts-mode-hook))
  (add-hook hook #'kitty--c-setup))

;;;; Build and run

(defun kitty-c--root ()
  (kitty-project-root))

(defun kitty-c--build-system ()
  "Which build system the project root uses: `cmake', `make' or nil."
  (let ((root (kitty-c--root)))
    (cond ((file-exists-p (expand-file-name "CMakeLists.txt" root)) 'cmake)
          ((file-exists-p (expand-file-name "Makefile" root)) 'make))))

(defun kitty-c-configure ()
  "Configure the CMake project in build/ (Ninja, compile_commands.json for clangd)."
  (interactive)
  (let ((default-directory (kitty-c--root)))
    (compile (concat "cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug "
                     "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"))))

(defun kitty-c-build ()
  "Build the project; a lone file without a build system is compiled directly."
  (interactive)
  (let ((default-directory (kitty-c--root)))
    (pcase (kitty-c--build-system)
      ('cmake (compile "cmake --build build"))
      ('make (compile "make -k"))
      (_ (kitty-c-compile-file)))))

(defun kitty-c-compile-file ()
  "Compile just this file to an executable next to it."
  (interactive)
  (let* ((file (or buffer-file-name (user-error "Save the buffer first")))
         (cxx (derived-mode-p 'c++-mode 'c++-ts-mode))
         (out (file-name-sans-extension file)))
    (compile (format "%s -g -Wall -Wextra %s -o %s"
                     (if cxx "c++ -std=c++20" "cc -std=c17")
                     (shell-quote-argument file) (shell-quote-argument out)))))

(defun kitty-c-run ()
  "Run the built executable (asks for it when the project has several)."
  (interactive)
  (let* ((default-directory (kitty-c--root))
         (candidates (when (file-directory-p "build")
                       (seq-filter (lambda (f) (and (file-executable-p f) (not (file-directory-p f))))
                                   (directory-files-recursively "build" "" nil
                                                                (lambda (d) (not (string-match-p "CMakeFiles" d)))))))
         (exe (cond (candidates (completing-read "Run: " candidates nil t))
                    (buffer-file-name (file-name-sans-extension buffer-file-name))
                    (t (user-error "Nothing to run")))))
    (compile (shell-quote-argument (expand-file-name exe)) t)))

(defun kitty-c-test ()
  "Run ctest."
  (interactive)
  (let ((default-directory (kitty-c--root)))
    (compile "ctest --test-dir build --output-on-failure")))

(defun kitty-c-debug ()
  "Debug an executable with gdb in Emacs."
  (interactive)
  (call-interactively #'gdb))

(dolist (mode '(c-mode c-ts-mode c++-mode c++-ts-mode))
  (kitty-local-leader mode
    "c" '("configure" . kitty-c-configure)
    "b" '("build" . kitty-c-build)
    "B" '("compile file" . kitty-c-compile-file)
    "r" '("run" . kitty-c-run)
    "t" '("ctest" . kitty-c-test)
    "d" '("debug (gdb)" . kitty-c-debug)
    "s" '("header / source" . ff-find-other-file)
    "f" '("format" . kitty-format)))

(provide 'kitty-c)
;;; kitty-c.el ends here
