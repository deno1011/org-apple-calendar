;;; org-apple-calendar.el --- Read Apple Calendar (EventKit) into org -*- lexical-binding: t; -*-
;;
;; Author: Denis Butic
;; Version: 0.2.0
;; Keywords: calendar, outlines
;; Package-Requires: ((emacs "29.1"))
;;
;; Read-only EventKit bridge (L1–L2): list calendars with owned/managed
;; classification; fetch events (later). The write path and ingest come later.
;; macOS only.
;;
;; Public API:
;;   (org-apple-calendar-list-calendars)   -> list of plists
;;   (org-apple-calendar-show-calendars)   -> interactive, tabulated view
;;
;;; Code:

(require 'json)

(defgroup org-apple-calendar nil
  "Read Apple Calendar (EventKit) into org."
  :group 'org)

(defcustom org-apple-calendar-access-timeout 25
  "Seconds to wait for the macOS Calendar-access grant / EventKit reply."
  :type 'integer :group 'org-apple-calendar)

(defun org-apple-calendar--jxa-run (script)
  "Run JXA SCRIPT via osascript and return its stdout as a string."
  (with-output-to-string
    (with-current-buffer standard-output
      (call-process "osascript" nil t nil "-l" "JavaScript" "-e" script))))

(defun org-apple-calendar--jxa-run-json (script)
  "Run JXA SCRIPT and parse its JSON stdout (objects->alist, arrays->list)."
  (let ((raw (string-trim (org-apple-calendar--jxa-run script))))
    (when (string-empty-p raw)
      (user-error "Calendar: empty reply (Calendar access denied or timed out)"))
    (condition-case nil
        (json-parse-string raw :object-type 'alist :array-type 'list
                           :false-object nil :null-object nil)
      (error (user-error "Calendar: could not parse reply: %s" raw)))))

(defconst org-apple-calendar--list-script-template
  "ObjC.import('EventKit');
var store=$.EKEventStore.alloc.init;
var done=false,granted=false,out=[];
store.requestAccessToEntityTypeCompletion($.EKEntityTypeEvent,function(g){granted=g;done=true;});
var iter=0,max=%d;
while(!done&&iter<max){$.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.1));iter++;}
if(granted){
  var cals=store.calendarsForEntityType($.EKEntityTypeEvent);
  for(var i=0;i<cals.count;i++){
    var c=cals.objectAtIndex(i);
    out.push({title:ObjC.unwrap(c.title),
              id:ObjC.unwrap(c.calendarIdentifier),
              writable:c.allowsContentModifications,
              type:c.type,
              source:(c.source?ObjC.unwrap(c.source.title):'')});
  }
}
JSON.stringify({granted:granted,calendars:out});"
  "JXA template; one %d placeholder = run-loop iterations (timeout*10).")

(defun org-apple-calendar--type-label (n)
  "Human label for EKCalendarType integer N."
  (pcase n (0 "Local") (1 "CalDAV") (2 "Exchange")
         (3 "Subscription") (4 "Birthday") (_ (format "Type%s" n))))

(defun org-apple-calendar-list-calendars ()
  "Return Apple event calendars as a list of plists.
Each plist: :title :id :writable (t = owned/managed-by-you) :type :source.
Signals a `user-error' if Calendar access is not granted."
  (let* ((script (format org-apple-calendar--list-script-template
                         (* 10 org-apple-calendar-access-timeout)))
         (data (org-apple-calendar--jxa-run-json script)))
    (unless (eq (alist-get 'granted data) t)
      (user-error "Calendar access not granted (approve the macOS prompt for Emacs)"))
    (let ((cals (mapcar (lambda (c)
                          (list :title (alist-get 'title c)
                                :id (alist-get 'id c)
                                :writable (eq (alist-get 'writable c) t)
                                :type (org-apple-calendar--type-label (alist-get 'type c))
                                :source (alist-get 'source c)))
                        (alist-get 'calendars data))))
      ;; First access auto-creates the per-user classification listing ALL
      ;; calendars (default busy); later calls append any new ones.
      (org-apple-calendar--sync-classification cals)
      cals)))

(defconst org-apple-calendar--ensure-calendar-template
  "ObjC.import('EventKit');
var store=$.EKEventStore.alloc.init;
var done=false,granted=false,out={};
store.requestAccessToEntityTypeCompletion($.EKEntityTypeEvent,function(g){granted=g;done=true;});
var it=0,max=%d;
while(!done&&it<max){$.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.1));it++;}
out.granted=granted;
if(granted){
  var cals=store.calendarsForEntityType($.EKEntityTypeEvent),found=null;
  for(var i=0;i<cals.count;i++){var c=cals.objectAtIndex(i);if(ObjC.unwrap(c.title)===%s){found=c;break;}}
  if(found){out.exists=true;out.id=ObjC.unwrap(found.calendarIdentifier);}
  else{try{
    var cal=$.EKCalendar.calendarForEntityTypeEventStore($.EKEntityTypeEvent,store);
    cal.title=%s;
    cal.source=store.defaultCalendarForNewEvents.source;
    var err=Ref();
    out.created=store.saveCalendarCommitError(cal,true,err);
    out.id=ObjC.unwrap(cal.calendarIdentifier);
  }catch(e){out.err=String(e);}}
}
JSON.stringify(out);"
  "JXA template; %d = run-loop iterations, then two %s = calendar name (JSON).")

(defun org-apple-calendar-ensure-calendar (name)
  "Ensure an Apple event calendar named NAME exists, creating it if absent.
Public, idempotent.  A newly created calendar inherits the default
new-event source (usually iCloud, so it syncs to all devices).  Returns an
alist: `exists' t when already present, else `created'/`id' (or `err').
Signals a `user-error' if Calendar access is not granted."
  (require 'json)
  (let* ((script (format org-apple-calendar--ensure-calendar-template
                         (* 10 org-apple-calendar-access-timeout)
                         (json-encode name) (json-encode name)))
         (data (org-apple-calendar--jxa-run-json script)))
    (unless (eq (alist-get 'granted data) t)
      (user-error "Calendar access not granted (approve the macOS prompt for Emacs)"))
    data))

(defun org-apple-calendar-show-calendars ()
  "Display all Apple calendars classified as owned (writable) vs read-only."
  (interactive)
  (let ((cals (org-apple-calendar-list-calendars))
        (buf (get-buffer-create "*Apple Calendars*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Apple Calendars — owned (writable) vs read-only (managed/subscribed)\n")
        (insert (make-string 72 ?-) "\n")
        (dolist (c (sort cals (lambda (a b)
                                (and (plist-get a :writable)
                                     (not (plist-get b :writable))))))
          (insert (format "%-4s %-12s %-28s %s\n"
                          (if (plist-get c :writable) "RW" "ro")
                          (plist-get c :type)
                          (truncate-string-to-width (or (plist-get c :title) "") 28)
                          (or (plist-get c :source) ""))))
        (goto-char (point-min))
        (view-mode 1)))
    (display-buffer buf)
    cals))

(defconst org-apple-calendar--events-script-template
  "ObjC.import('EventKit');
var store=$.EKEventStore.alloc.init;
var done=false,granted=false,out=[];
store.requestAccessToEntityTypeCompletion($.EKEntityTypeEvent,function(g){granted=g;done=true;});
var it=0,mx=%d;
while(!done&&it<mx){$.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.1));it++;}
if(granted){
  var s=$.NSDate.dateWithTimeIntervalSince1970(%f);
  var e=$.NSDate.dateWithTimeIntervalSince1970(%f);
  var pred=store.predicateForEventsWithStartDateEndDateCalendars(s,e,$());
  var evs=store.eventsMatchingPredicate(pred);
  for(var i=0;i<evs.count;i++){
    var ev=evs.objectAtIndex(i);
    out.push({title:(ev.title?ObjC.unwrap(ev.title):''),
              start:ev.startDate.timeIntervalSince1970,
              end:ev.endDate.timeIntervalSince1970,
              allDay:ev.allDay,
              cal:(ev.calendar?ObjC.unwrap(ev.calendar.title):''),
              uid:(ev.eventIdentifier?ObjC.unwrap(ev.eventIdentifier):''),
              avail:ev.availability,
              mod:(ev.lastModifiedDate?ev.lastModifiedDate.timeIntervalSince1970:0),
              notes:(ev.notes?ObjC.unwrap(ev.notes):''),
              recurring:(ev.hasRecurrenceRules?true:false)});
  }
}
JSON.stringify({granted:granted,events:out});"
  "JXA template: one %d (run-loop iters), two %f (start/end unix seconds).")

(defun org-apple-calendar-fetch-events (start end)
  "Return events between START and END (Emacs time values) as plists.
Each: :title :start :end (Emacs time) :all-day :calendar :notes :recurring."
  (let* ((script (format org-apple-calendar--events-script-template
                         (* 10 org-apple-calendar-access-timeout)
                         (float-time start) (float-time end)))
         (data (org-apple-calendar--jxa-run-json script)))
    (unless (eq (alist-get 'granted data) t)
      (user-error "Calendar access not granted (approve the macOS prompt for Emacs)"))
    (mapcar (lambda (ev)
              (list :title (alist-get 'title ev)
                    :start (seconds-to-time (alist-get 'start ev))
                    :end (seconds-to-time (alist-get 'end ev))
                    :all-day (eq (alist-get 'allDay ev) t)
                    :calendar (alist-get 'cal ev)
                    :uid (alist-get 'uid ev)
                    :availability (alist-get 'avail ev)
                    :mod (alist-get 'mod ev)
                    :notes (alist-get 'notes ev)
                    :recurring (eq (alist-get 'recurring ev) t)))
            (alist-get 'events data))))

(defun org-apple-calendar-free-busy (start end)
  "Return merged busy intervals (list of (BEG . END) Emacs-time pairs) in [START,END).
Timed events count as busy; all-day events are ignored."
  (let ((ivs (sort (delq nil (mapcar (lambda (ev)
                                       (when (and (not (plist-get ev :all-day))
                                                  (eq (org-apple-calendar--event-role ev) 'busy))
                                         (cons (plist-get ev :start) (plist-get ev :end))))
                                     (org-apple-calendar-fetch-events start end)))
                   (lambda (a b) (time-less-p (car a) (car b)))))
        (merged '()))
    (dolist (iv ivs)
      (let ((last (car merged)))
        (if (and last (not (time-less-p (cdr last) (car iv))))
            (when (time-less-p (cdr last) (cdr iv))
              (setcdr last (cdr iv)))
          (push iv merged))))
    (nreverse merged)))

(defun org-apple-calendar-upcoming (&optional days)
  "Display events for the next DAYS (default 14) across all calendars."
  (interactive "P")
  (let* ((days (if days (prefix-numeric-value days) 14))
         (start (current-time))
         (end (time-add start (days-to-time days)))
         (evs (sort (org-apple-calendar-fetch-events start end)
                    (lambda (a b) (time-less-p (plist-get a :start)
                                               (plist-get b :start)))))
         (buf (get-buffer-create "*Apple Calendar — Upcoming*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Upcoming — next %d days (%d events)\n" days (length evs)))
        (insert (make-string 72 ?-) "\n")
        (dolist (ev evs)
          (let ((role (org-apple-calendar--event-role ev)))
            (unless (eq role 'ignore)
              (insert (propertize
                       (format "%s %s  %-20s %s%s\n"
                               (pcase role ('busy "●") ('info "○") (_ "·"))
                               (format-time-string
                                (if (plist-get ev :all-day) "%a %d.%m.      " "%a %d.%m. %H:%M")
                                (plist-get ev :start))
                               (truncate-string-to-width (or (plist-get ev :calendar) "") 20)
                               (or (plist-get ev :title) "")
                               (if (plist-get ev :recurring) " ↻" ""))
                       'apple-uid (plist-get ev :uid)
                       'apple-event ev)))))
        (goto-char (point-min)) (view-mode 1)))
    (display-buffer buf)))

(defcustom org-apple-calendar-info-calendars nil
  "Calendar titles whose events are context/info — never block free time."
  :type '(repeat string) :group 'org-apple-calendar)

(defcustom org-apple-calendar-ignore-calendars nil
  "Calendar titles whose events are hidden entirely (e.g. week numbers)."
  :type '(repeat string) :group 'org-apple-calendar)

(defcustom org-apple-calendar-overrides-file
  (expand-file-name "org-apple-calendar/overrides.eld" user-emacs-directory)
  "File persisting per-event role overrides as an alist (UID . ROLE)."
  :type 'file :group 'org-apple-calendar)

(defvar org-apple-calendar--overrides 'unset
  "Cached overrides alist (UID . ROLE); `unset' until first load.")

(defun org-apple-calendar--load-overrides ()
  "Load and cache the per-event role overrides."
  (when (eq org-apple-calendar--overrides 'unset)
    (setq org-apple-calendar--overrides
          (when (file-exists-p org-apple-calendar-overrides-file)
            (with-temp-buffer
              (insert-file-contents org-apple-calendar-overrides-file)
              (ignore-errors (read (current-buffer)))))))
  org-apple-calendar--overrides)

(defun org-apple-calendar--save-overrides ()
  "Persist the overrides alist."
  (make-directory (file-name-directory org-apple-calendar-overrides-file) t)
  (with-temp-file org-apple-calendar-overrides-file
    (prin1 org-apple-calendar--overrides (current-buffer))))

(defun org-apple-calendar-set-event-role (uid role)
  "Persist ROLE (`busy'/`info'/`ignore', or nil to clear) as override for UID."
  (org-apple-calendar--load-overrides)
  (setq org-apple-calendar--overrides
        (assoc-delete-all uid org-apple-calendar--overrides))
  (when role (push (cons uid role) org-apple-calendar--overrides))
  (org-apple-calendar--save-overrides)
  role)

(defun org-apple-calendar--event-role (ev)
  "Effective role of EV: `busy', `info', or `ignore'.
Priority: per-event override > ignore/info calendar policy > Apple
availability (Free ⇒ info) > default busy."
  (let* ((ovr (cdr (assoc (plist-get ev :uid) (org-apple-calendar--load-overrides))))
         (cal (plist-get ev :calendar))
         (cls (cdr (assoc cal (org-apple-calendar--load-classification)))))
    (cond
     (ovr ovr)                                       ; per-event override
     (cls cls)                                        ; per-calendar policy file
     ((member cal org-apple-calendar-ignore-calendars) 'ignore)
     ((member cal org-apple-calendar-info-calendars) 'info)
     ((eql (plist-get ev :availability) 1) 'info)   ; EKEventAvailabilityFree
     (t 'busy))))

(defun org-apple-calendar--uid-at-point ()
  "Apple event UID at point: from the `apple-uid' text prop or org property."
  (or (get-text-property (point) 'apple-uid)
      (and (derived-mode-p 'org-mode) (org-entry-get nil "APPLE_EVENT_UID"))))

(defun org-apple-calendar-override-role (role)
  "Override the busy/info/ignore ROLE for the calendar event at point.
Works in the upcoming/free buffers (text prop) and the agenda mirror (org
property). Choosing \"clear\" removes the override."
  (interactive
   (list (let ((r (completing-read "Rolle (busy/info/ignore/clear): "
                                   '("busy" "info" "ignore" "clear") nil t)))
           (unless (string= r "clear") (intern r)))))
  (let ((uid (org-apple-calendar--uid-at-point)))
    (unless uid (user-error "Kein Apple-Event an dieser Stelle"))
    (org-apple-calendar-set-event-role uid role)
    (message "Rolle gesetzt: %s — View neu laden (C-c k u / m) zum Aktualisieren"
             (or role "default"))))

(defcustom org-apple-calendar-classification-file nil
  "File mapping each calendar title to a role: an alist (NAME . busy|info|ignore).
Keep it in your private/encrypted data area. Auto-populated with all calendars
on first access; nil disables the per-calendar policy file."
  :type '(choice (const nil) file) :group 'org-apple-calendar)

(defvar org-apple-calendar--classification 'unset
  "Cached classification alist; `unset' until first load.")

(defun org-apple-calendar--load-classification ()
  "Load and cache the per-calendar classification alist."
  (when (eq org-apple-calendar--classification 'unset)
    (setq org-apple-calendar--classification
          (when (and org-apple-calendar-classification-file
                     (file-exists-p org-apple-calendar-classification-file))
            (with-temp-buffer
              (insert-file-contents org-apple-calendar-classification-file)
              (ignore-errors (read (current-buffer)))))))
  org-apple-calendar--classification)

(defun org-apple-calendar--save-classification (alist)
  "Persist the classification ALIST."
  (when org-apple-calendar-classification-file
    (make-directory (file-name-directory org-apple-calendar-classification-file) t)
    (with-temp-file org-apple-calendar-classification-file
      (insert ";; org-apple-calendar: calendar title -> role (busy|info|ignore).\n"
              ";; Edit roles freely; new calendars are appended as `busy'.\n")
      (prin1 alist (current-buffer))
      (insert "\n"))
    (setq org-apple-calendar--classification alist)))

(defun org-apple-calendar--sync-classification (cals)
  "Append any calendars in CALS missing from the classification file as `busy'."
  (when org-apple-calendar-classification-file
    (let ((cur (copy-alist (org-apple-calendar--load-classification)))
          (changed nil))
      (dolist (c cals)
        (let ((name (plist-get c :title)))
          (unless (assoc name cur) (push (cons name 'busy) cur) (setq changed t))))
      (when changed (org-apple-calendar--save-classification cur)))))

(defun org-apple-calendar-init-classification ()
  "Ensure every calendar appears in the classification file, then open it.
New calendars are added as `busy'; existing roles are preserved."
  (interactive)
  (unless org-apple-calendar-classification-file
    (user-error "Set `org-apple-calendar-classification-file' first"))
  (org-apple-calendar--sync-classification (org-apple-calendar-list-calendars))
  (find-file org-apple-calendar-classification-file))

(defcustom org-apple-calendar-day-window '(9 . 21)
  "Daily availability window as (START-HOUR . END-HOUR), local time."
  :type '(cons integer integer) :group 'org-apple-calendar)

(defun org-apple-calendar--day-floor (epoch)
  "Return local-midnight epoch for the day containing EPOCH (a float)."
  (let ((d (decode-time (seconds-to-time epoch))))
    (float-time (encode-time 0 0 0 (decoded-time-day d)
                             (decoded-time-month d) (decoded-time-year d)))))

(defun org-apple-calendar-free-slots (start end &optional min-minutes)
  "Return free slots (list of (BEG . END) Emacs-time pairs) in [START,END].
Each slot lies inside the daily `org-apple-calendar-day-window', is at least
MIN-MINUTES long (default 30), starts no earlier than now, and avoids busy
intervals from `org-apple-calendar-free-busy'."
  (let* ((min-secs (* 60 (or min-minutes 30)))
         (busy (mapcar (lambda (b) (cons (float-time (car b)) (float-time (cdr b))))
                       (org-apple-calendar-free-busy start end)))
         (now (float-time))
         (ws (car org-apple-calendar-day-window))
         (we (cdr org-apple-calendar-day-window))
         (e (float-time end))
         (day (org-apple-calendar--day-floor (float-time start)))
         (slots '()))
    (while (< day e)
      (let ((ds (max now (+ day (* 3600 ws))))
            (de (min e (+ day (* 3600 we))))
            (cursor nil))
        (when (< ds de)
          (setq cursor ds)
          (dolist (b busy)
            (let ((bs (car b)) (be (cdr b)))
              (when (and (< bs de) (> be ds))      ; overlaps this day window
                (when (and (> bs cursor) (>= (- bs cursor) min-secs))
                  (push (cons cursor bs) slots))
                (setq cursor (max cursor be)))))
          (when (and (< cursor de) (>= (- de cursor) min-secs))
            (push (cons cursor de) slots))))
      (setq day (+ day 86400)))
    (nreverse (mapcar (lambda (s) (cons (seconds-to-time (car s))
                                        (seconds-to-time (cdr s))))
                      slots))))

(defun org-apple-calendar-show-free-slots (&optional days min-minutes)
  "Display free slots for the next DAYS (default 7), each >= MIN-MINUTES (60)."
  (interactive)
  (let* ((days (or days 7))
         (min-minutes (or min-minutes 60))
         (start (current-time))
         (end (time-add start (days-to-time days)))
         (slots (org-apple-calendar-free-slots start end min-minutes))
         (buf (get-buffer-create "*Apple Calendar — Free*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Free slots — next %d days, >= %d min, window %d:00-%d:00\n"
                        days min-minutes (car org-apple-calendar-day-window)
                        (cdr org-apple-calendar-day-window)))
        (insert (make-string 56 ?-) "\n")
        (dolist (sl slots)
          (insert (format "%s  %s–%s  (%d min)\n"
                          (format-time-string "%a %d.%m." (car sl))
                          (format-time-string "%H:%M" (car sl))
                          (format-time-string "%H:%M" (cdr sl))
                          (round (/ (float-time (time-subtract (cdr sl) (car sl))) 60)))))
        (goto-char (point-min)) (view-mode 1)))
    (display-buffer buf)
    slots))

(defcustom org-apple-calendar-mirror-file
  (expand-file-name "org-apple-calendar/calendar-mirror.org" user-emacs-directory)
  "Path of the regenerable read-only org mirror of Apple calendars."
  :type 'file :group 'org-apple-calendar)

(defcustom org-apple-calendar-mirror-days 30
  "How many days ahead to mirror."
  :type 'integer :group 'org-apple-calendar)

(defun org-apple-calendar--event-timestamp (ev)
  "Return an org active timestamp string for event EV."
  (if (plist-get ev :all-day)
      (format-time-string "<%Y-%m-%d %a>" (plist-get ev :start))
    (let ((bs (plist-get ev :start)) (be (plist-get ev :end)))
      (if (string= (format-time-string "%Y-%m-%d" bs)
                   (format-time-string "%Y-%m-%d" be))
          (concat (format-time-string "<%Y-%m-%d %a %H:%M" bs)
                  (format-time-string "-%H:%M>" be))
        (concat (format-time-string "<%Y-%m-%d %a %H:%M>--" bs)
                (format-time-string "<%Y-%m-%d %a %H:%M>" be))))))

(defun org-apple-calendar-refresh-mirror (&optional days)
  "Regenerate `org-apple-calendar-mirror-file' for the next DAYS and add it to
`org-agenda-files'. Returns the event count."
  (interactive)
  (let* ((days (or days org-apple-calendar-mirror-days))
         (start (current-time))
         (end (time-add start (days-to-time days)))
         (evs (sort (org-apple-calendar-fetch-events start end)
                    (lambda (a b) (time-less-p (plist-get a :start)
                                               (plist-get b :start)))))
         (file org-apple-calendar-mirror-file))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert "#+TITLE: Apple Calendar (read-only mirror)\n"
              "#+STARTUP: overview\n"
              "# AUTO-GENERATED by org-apple-calendar — do not edit (overwritten on refresh).\n"
              "# Visibility only. Create appointments in calendar.org, not here.\n\n")
      (dolist (ev evs)
        (let ((role (org-apple-calendar--event-role ev)))
          (unless (eq role 'ignore)
            (insert (format "* %s%s\n  :PROPERTIES:\n  :CALENDAR: %s\n  :APPLE_EVENT_UID: %s\n  :END:\n  %s\n"
                            (or (plist-get ev :title) "(ohne Titel)")
                            (if (eq role 'info) " :info:" "")
                            (or (plist-get ev :calendar) "")
                            (or (plist-get ev :uid) "")
                            (org-apple-calendar--event-timestamp ev)))))))
    (add-to-list 'org-agenda-files file)
    (when (called-interactively-p 'any)
      (message "Calendar mirror: %d events → %s" (length evs) file))
    (length evs)))

;; -- Idle auto-refresh (read-only; the write sync stays manual) --------------

(defcustom org-apple-calendar-auto-refresh-interval nil
  "Idle seconds before auto-refreshing the read-only mirror; nil disables.
Only the read-only mirror is refreshed automatically (safe). The two-way write
sync (`org-apple-calendar-sync-appointments') stays manual on purpose."
  :type '(choice (const :tag "off" nil) integer) :group 'org-apple-calendar)

(defvar org-apple-calendar--auto-timer nil
  "Idle timer object for the mirror auto-refresh.")

(defun org-apple-calendar--auto-refresh-tick ()
  "Refresh the mirror when configured; never signals."
  (when org-apple-calendar-mirror-file
    (ignore-errors (org-apple-calendar-refresh-mirror))))

(defun org-apple-calendar-setup-auto-refresh ()
  "Start or restart the idle mirror-refresh timer per the interval defcustom."
  (interactive)
  (when (timerp org-apple-calendar--auto-timer)
    (cancel-timer org-apple-calendar--auto-timer))
  (setq org-apple-calendar--auto-timer nil)
  (when (and (integerp org-apple-calendar-auto-refresh-interval)
             (> org-apple-calendar-auto-refresh-interval 0))
    (setq org-apple-calendar--auto-timer
          (run-with-idle-timer org-apple-calendar-auto-refresh-interval t
                               #'org-apple-calendar--auto-refresh-tick))))

(defcustom org-apple-calendar-ingest-calendars 'read-only
  "Which calendars feed the deadline ingest.
`read-only' = every non-writable (subscribed/managed) calendar; or a list of
calendar title strings."
  :type '(choice (const :tag "All read-only calendars" read-only)
                 (repeat string))
  :group 'org-apple-calendar)

(defcustom org-apple-calendar-deadline-keywords
  '("Abgabe" "Frist" "Deadline" "fällig" "Einsendeaufgabe" "Klassenfahrt"
    "mitbringen" "zahlen" "bezahlen" "Einverständnis" "Einwilligung"
    "Anmeldung" "anmelden" "Antrag" "Genehmigung" "Zettel")
  "Case-insensitive substrings that mark a calendar event as a task candidate."
  :type '(repeat string) :group 'org-apple-calendar)

(defcustom org-apple-calendar-ingest-file nil
  "Org file that ingested NEXT tasks are appended to (e.g. gtd/next.org).
Must be set before `org-apple-calendar-ingest-deadlines' can create tasks."
  :type '(choice (const nil) file) :group 'org-apple-calendar)

(defcustom org-apple-calendar-ingest-days 60
  "How many days ahead the deadline ingest scans."
  :type 'integer :group 'org-apple-calendar)

(defun org-apple-calendar--readonly-calendar-names ()
  "Titles of all non-writable (subscribed/managed) calendars."
  (delq nil (mapcar (lambda (c) (unless (plist-get c :writable)
                                  (plist-get c :title)))
                    (org-apple-calendar-list-calendars))))

(defun org-apple-calendar--ingest-calendar-names ()
  "Resolve `org-apple-calendar-ingest-calendars' to a list of titles."
  (if (eq org-apple-calendar-ingest-calendars 'read-only)
      (org-apple-calendar--readonly-calendar-names)
    org-apple-calendar-ingest-calendars))

(defun org-apple-calendar--deadline-candidate-p (ev)
  "Non-nil if EV's title matches any `org-apple-calendar-deadline-keywords'."
  (let ((title (or (plist-get ev :title) ""))
        (case-fold-search t))
    (seq-some (lambda (kw) (string-match-p (regexp-quote kw) title))
              org-apple-calendar-deadline-keywords)))

(defun org-apple-calendar--ingest-key (ev)
  "Stable idempotency key for EV: UID@START-epoch."
  (format "%s@%d" (or (plist-get ev :uid) "")
          (floor (float-time (plist-get ev :start)))))

(defun org-apple-calendar--already-ingested-p (key)
  "Non-nil if KEY already appears in `org-apple-calendar-ingest-file'."
  (let ((file org-apple-calendar-ingest-file))
    (and file (file-exists-p file)
         (with-temp-buffer
           (insert-file-contents file)
           (search-forward key nil t)))))

(defun org-apple-calendar-ingest-candidates (&optional days)
  "Return task-candidate events from the ingest calendars not yet ingested."
  (let* ((days (or days org-apple-calendar-ingest-days))
         (start (current-time))
         (end (time-add start (days-to-time days)))
         (cals (org-apple-calendar--ingest-calendar-names)))
    (seq-filter
     (lambda (ev)
       (and (member (plist-get ev :calendar) cals)
            (org-apple-calendar--deadline-candidate-p ev)
            (not (org-apple-calendar--already-ingested-p
                  (org-apple-calendar--ingest-key ev)))))
     (org-apple-calendar-fetch-events start end))))

(defun org-apple-calendar--create-ingest-task (ev)
  "Append a linked NEXT + SCHEDULED heading for EV to the ingest file."
  (let ((file org-apple-calendar-ingest-file))
    (unless (and file (stringp file))
      (user-error "Set `org-apple-calendar-ingest-file' first"))
    (let ((sched (if (plist-get ev :all-day)
                     (format-time-string "<%Y-%m-%d %a>" (plist-get ev :start))
                   (format-time-string "<%Y-%m-%d %a %H:%M>" (plist-get ev :start)))))
      (with-current-buffer (find-file-noselect file)
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert (format "* NEXT %s\n  SCHEDULED: %s\n  :PROPERTIES:\n  :APPLE_EVENT_ID: %s\n  :APPLE_CALENDAR: %s\n  :END:\n"
                        (or (plist-get ev :title) "(Termin)")
                        sched
                        (org-apple-calendar--ingest-key ev)
                        (or (plist-get ev :calendar) "")))
        (save-buffer)))))

(defun org-apple-calendar-ingest-deadlines (&optional days)
  "Scan read-only calendars for task candidates; confirm each; create NEXT tasks.
Created headings carry SCHEDULED = the event date and an `:APPLE_EVENT_ID:' so
re-running never duplicates. The source calendar is never modified."
  (interactive)
  (let ((cands (org-apple-calendar-ingest-candidates days))
        (made 0))
    (if (null cands)
        (message "Ingest: no new task candidates.")
      (dolist (ev cands)
        (when (y-or-n-p (format "Aufgabe anlegen? [%s] %s — %s "
                                (plist-get ev :calendar)
                                (format-time-string "%d.%m." (plist-get ev :start))
                                (plist-get ev :title)))
          (org-apple-calendar--create-ingest-task ev)
          (cl-incf made)))
      (message "Ingest: %d task(s) created in %s" made
               (file-name-nondirectory (or org-apple-calendar-ingest-file "?"))))))

(require 'org-element)

(defcustom org-apple-calendar-write-backend 'eventkit
  "Backend for writing appointments to Apple Calendar."
  :type '(choice (const eventkit) (const caldav)) :group 'org-apple-calendar)

(defcustom org-apple-calendar-target-calendar "Org"
  "Name of the single Apple calendar this package writes to."
  :type 'string :group 'org-apple-calendar)

(defcustom org-apple-calendar-source-file nil
  "Org file whose active-timestamp headings are pushed as appointments."
  :type '(choice (const nil) file) :group 'org-apple-calendar)

(defconst org-apple-calendar--create-script-template
  "ObjC.import('EventKit');
var store=$.EKEventStore.alloc.init;
var done=false,granted=false,res={};
store.requestAccessToEntityTypeCompletion($.EKEntityTypeEvent,function(g){granted=g;done=true;});
var it=0;while(!done&&it<%d){$.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.1));it++;}
if(granted){
  var cals=store.calendarsForEntityType($.EKEntityTypeEvent),cal=null,tgt=%s;
  for(var i=0;i<cals.count;i++){var c=cals.objectAtIndex(i);if(ObjC.unwrap(c.title)===tgt){cal=c;break;}}
  if(!cal){res.err='calendar-not-found';}
  else{
    var ev=$.EKEvent.eventWithEventStore(store);
    ev.title=%s;ev.calendar=cal;
    ev.startDate=$.NSDate.dateWithTimeIntervalSince1970(%f);
    ev.endDate=$.NSDate.dateWithTimeIntervalSince1970(%f);
    ev.allDay=%s;
    var notes=%s;if(notes){ev.notes=notes;}
    var rfreq=%d,rint=%d;
    if(rfreq>=0){ev.addRecurrenceRule($.EKRecurrenceRule.alloc.initRecurrenceWithFrequencyIntervalEnd(rfreq,rint,$()));}
    if(store.saveEventSpanError(ev,0,$())){res.ok=true;res.uid=ObjC.unwrap(ev.eventIdentifier);res.mod=ev.lastModifiedDate.timeIntervalSince1970;}
    else{res.err='save-failed';}
  }
}
JSON.stringify({granted:granted,result:res});"
  "JXA template: %d iters, %s target, %s title, %f start, %f end, %s allDay,
%s notes, %d recurrence frequency (-1 = none; 0/1/2/3 = daily/weekly/monthly/
yearly), %d recurrence interval.")

(defun org-apple-calendar--eventkit-create-event (title start end all-day notes
                                                        &optional recurrence)
  "Create an event in `org-apple-calendar-target-calendar' via EventKit.
START/END are epoch seconds. RECURRENCE is a plist (:freq daily|weekly|monthly|
yearly :interval N) or nil. Return plist with :uid on success or :error."
  (let* ((rfreq (pcase (plist-get recurrence :freq)
                  ('daily 0) ('weekly 1) ('monthly 2) ('yearly 3) (_ -1)))
         (rint (or (plist-get recurrence :interval) 1))
         (script (format org-apple-calendar--create-script-template
                         (* 10 org-apple-calendar-access-timeout)
                         (json-encode org-apple-calendar-target-calendar)
                         (json-encode (or title "(Termin)"))
                         (float start) (float end)
                         (if all-day "true" "false")
                         (if (and notes (not (string-empty-p notes)))
                             (json-encode notes) "null")
                         rfreq rint))
         (data (org-apple-calendar--jxa-run-json script))
         (res (alist-get 'result data)))
    (cond
     ((not (eq (alist-get 'granted data) t)) (list :error "no-access"))
     ((alist-get 'uid res) (list :uid (alist-get 'uid res) :mod (alist-get 'mod res)))
     (t (list :error (or (alist-get 'err res) "unknown"))))))

(defun org-apple-calendar--timestamp-recurrence (ts)
  "Return a recurrence plist (:freq :interval) for org timestamp TS, or nil.
Maps the org repeater unit to an EKRecurrenceRule frequency. Hour repeaters
are unsupported (EKRecurrenceRule has no sub-day frequency)."
  (when (org-element-property :repeater-type ts)
    (let ((val (or (org-element-property :repeater-value ts) 1))
          (unit (org-element-property :repeater-unit ts)))
      (pcase unit
        ('day   (list :freq 'daily :interval val))
        ('week  (list :freq 'weekly :interval val))
        ('month (list :freq 'monthly :interval val))
        ('year  (list :freq 'yearly :interval val))
        (_ nil)))))

(defun org-apple-calendar--entry-appointment ()
  "Return a plist for the appointment at point, or nil when it has no timestamp.
Plist: :title :start :end (epoch) :all-day :notes :recurrence."
  (let ((tsstr (org-entry-get nil "TIMESTAMP")))
    (when tsstr
      (let* ((ts (org-timestamp-from-string tsstr))
             (all-day (not (org-element-property :hour-start ts)))
             (start (float-time (org-timestamp-to-time ts)))
             (end (float-time (org-timestamp-to-time ts t))))
        (when (and (not all-day) (<= end start)) (setq end (+ start 3600)))
        (list :title (org-get-heading t t t t)
              :start start :end end :all-day all-day :notes nil
              :recurrence (org-apple-calendar--timestamp-recurrence ts))))))

(defun org-apple-calendar--event-at-point ()
  "Return the Apple calendar event represented at point.
Works in `org-apple-calendar-upcoming' buffers via text properties and in the
read-only org mirror via heading/timestamp/properties."
  (or (get-text-property (point) 'apple-event)
      (and (derived-mode-p 'org-mode)
           (save-excursion
             (org-back-to-heading t)
             (let* ((title (org-get-heading t t t t))
                    (end (save-excursion (org-end-of-subtree t t)))
                    uid cal tsstr)
               (save-excursion
                 (when (re-search-forward org-ts-regexp end t)
                   (setq tsstr (match-string 0)))
                 (goto-char (line-beginning-position))
                 (while (and (not (and uid cal))
                             (re-search-forward
                              "^[ \t]*:\\(APPLE_EVENT_UID\\|CALENDAR\\):[ \t]*\\(.*\\)$"
                              end t))
                   (pcase (match-string 1)
                     ("APPLE_EVENT_UID" (setq uid (string-trim (match-string 2))))
                     ("CALENDAR" (setq cal (string-trim (match-string 2)))))))
               (when (and uid tsstr)
                 (let* ((ts (org-timestamp-from-string tsstr))
                        (all-day (not (org-element-property :hour-start ts)))
                        (start (org-timestamp-to-time ts))
                        (ev-end (org-timestamp-to-time ts t)))
                   (when (and (not all-day)
                              (<= (float-time ev-end) (float-time start)))
                     (setq ev-end (time-add start (seconds-to-time 3600))))
                   (list :title title :start start :end ev-end :all-day all-day
                         :calendar cal :uid uid :notes nil))))))))

(defun org-apple-calendar--adopt-key (ev)
  "Return a stable source-occurrence key for adopted event EV."
  (format "%s@%d" (or (plist-get ev :uid) "")
          (floor (float-time (plist-get ev :start)))))

(defun org-apple-calendar--source-file-contains-key-p (key)
  "Non-nil when `org-apple-calendar-source-file' already contains KEY."
  (and org-apple-calendar-source-file
       (file-exists-p org-apple-calendar-source-file)
       (with-temp-buffer
         (insert-file-contents org-apple-calendar-source-file)
         (search-forward key nil t))))

(defun org-apple-calendar--append-adopted-appointment (ev apple-uid)
  "Append EV as an adopted appointment linked to APPLE-UID."
  (let ((file org-apple-calendar-source-file)
        (key (org-apple-calendar--adopt-key ev)))
    (unless (and file (stringp file))
      (user-error "Set `org-apple-calendar-source-file' first"))
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert (format "* %s\n  :PROPERTIES:\n  :ADOPTED_FROM_CALENDAR: %s\n  :ADOPTED_FROM_UID: %s\n  :ADOPTED_FROM_KEY: %s\n  :APPLE_EVENT_ID: %s\n  :APPLE_CALENDAR: %s\n  :END:\n  %s\n"
                      (or (plist-get ev :title) "(Termin)")
                      (or (plist-get ev :calendar) "")
                      (or (plist-get ev :uid) "")
                      key
                      apple-uid
                      org-apple-calendar-target-calendar
                      (org-apple-calendar--event-timestamp ev)))
      (save-buffer))))

(defun org-apple-calendar-adopt-event-at-point ()
  "Adopt the Apple event at point into `org-apple-calendar-source-file'.

The adopted appointment is created in `org-apple-calendar-target-calendar',
linked back into `calendar.org' with `APPLE_EVENT_ID', and the original source
event is marked `ignore' in the local override file so the mirror does not show
both copies. For recurring source events, the override applies to the source UID
and therefore hides all occurrences represented by that UID."
  (interactive)
  (unless (eq org-apple-calendar-write-backend 'eventkit)
    (user-error "Adopt requires the EventKit write backend"))
  (let* ((ev (org-apple-calendar--event-at-point))
         (source-uid (and ev (plist-get ev :uid)))
         (key (and ev (org-apple-calendar--adopt-key ev))))
    (unless ev
      (user-error "No Apple calendar event at point"))
    (unless source-uid
      (user-error "Event at point has no Apple UID"))
    (when (string= (or (plist-get ev :calendar) "")
                   org-apple-calendar-target-calendar)
      (user-error "Event is already in target calendar `%s'"
                  org-apple-calendar-target-calendar))
    (when (org-apple-calendar--source-file-contains-key-p key)
      (user-error "This event occurrence is already adopted"))
    (when (and (called-interactively-p 'any)
               (not (y-or-n-p
                     (format "Adopt '%s' into %s and ignore source? "
                             (or (plist-get ev :title) "(Termin)")
                             org-apple-calendar-target-calendar))))
      (user-error "Adopt cancelled"))
    (let ((res (org-apple-calendar--eventkit-create-event
                (plist-get ev :title)
                (float-time (plist-get ev :start))
                (float-time (plist-get ev :end))
                (plist-get ev :all-day)
                (plist-get ev :notes))))
      (unless (plist-get res :uid)
        (user-error "Adopt failed: %s" (or (plist-get res :error) "unknown")))
      (org-apple-calendar--append-adopted-appointment ev (plist-get res :uid))
      (org-apple-calendar-set-event-role source-uid 'ignore)
      (ignore-errors (org-apple-calendar-refresh-mirror))
      (message "Adopted '%s' into %s and ignored source event"
               (or (plist-get ev :title) "(Termin)")
               org-apple-calendar-target-calendar)
      (plist-get res :uid))))

(defconst org-apple-calendar--delete-script-template
  "ObjC.import('EventKit');
var store=$.EKEventStore.alloc.init;
var done=false,granted=false,res={};
store.requestAccessToEntityTypeCompletion($.EKEntityTypeEvent,function(g){granted=g;done=true;});
var it=0;while(!done&&it<%d){$.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.1));it++;}
if(granted){
  var ev=store.eventWithIdentifier(%s);
  if(!ev){res.gone=true;}
  else if(store.removeEventSpanError(ev,0,$())){res.ok=true;}
  else{res.err='remove-failed';}
}
JSON.stringify({granted:granted,result:res});"
  "JXA template: %d iters, %s event identifier (json-encoded).")

(defun org-apple-calendar--eventkit-delete-event (uid)
  "Delete the event with identifier UID from Apple Calendar.
Return plist (:ok / :gone / :error)."
  (let* ((script (format org-apple-calendar--delete-script-template
                         (* 10 org-apple-calendar-access-timeout)
                         (json-encode uid)))
         (data (org-apple-calendar--jxa-run-json script))
         (res (alist-get 'result data)))
    (cond
     ((not (eq (alist-get 'granted data) t)) (list :error "no-access"))
     ((eq (alist-get 'ok res) t) (list :ok t))
     ((eq (alist-get 'gone res) t) (list :gone t))
     (t (list :error (or (alist-get 'err res) "unknown"))))))

(defun org-apple-calendar-push-appointments ()
  "Push new appointments from `org-apple-calendar-source-file' to the Org calendar.
A heading is pushed when it has an active timestamp and no `:APPLE_EVENT_ID:'.
On success the heading is linked (idempotent). Update/delete come later."
  (interactive)
  (unless (eq org-apple-calendar-write-backend 'eventkit)
    (user-error "Write backend is `caldav' — use `org-caldav-sync' instead"))
  (let ((file org-apple-calendar-source-file) (made 0) (errs 0))
    (unless (and file (file-exists-p file))
      (user-error "Set `org-apple-calendar-source-file' (e.g. calendar.org)"))
    (with-current-buffer (find-file-noselect file)
      (org-with-wide-buffer
       (goto-char (point-min))
       (org-map-entries
        (lambda ()
          (let ((appt (and (not (org-entry-get nil "APPLE_EVENT_ID"))
                           (org-apple-calendar--entry-appointment))))
            (when appt
              (let ((res (org-apple-calendar--eventkit-create-event
                          (plist-get appt :title) (plist-get appt :start)
                          (plist-get appt :end) (plist-get appt :all-day)
                          (plist-get appt :notes) (plist-get appt :recurrence))))
                (if (plist-get res :uid)
                    (progn
                      (org-set-property "APPLE_EVENT_ID" (plist-get res :uid))
                      (org-set-property "APPLE_CALENDAR"
                                        org-apple-calendar-target-calendar)
                      (when (plist-get res :mod)
                        (org-set-property "APPLE_MOD"
                                          (number-to-string (plist-get res :mod))))
                      (cl-incf made))
                  (cl-incf errs))))))
        nil nil))
      (save-buffer))
    (message "Pushed %d appointment(s) to \"%s\", %d error(s)"
             made org-apple-calendar-target-calendar errs)))

;; -- Two-way sync (Apple "Org" calendar <-> calendar.org) -------------------

(defconst org-apple-calendar--update-script-template
  "ObjC.import('EventKit');
var store=$.EKEventStore.alloc.init;
var done=false,granted=false,res={};
store.requestAccessToEntityTypeCompletion($.EKEntityTypeEvent,function(g){granted=g;done=true;});
var it=0;while(!done&&it<%d){$.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.1));it++;}
if(granted){
  var ev=store.eventWithIdentifier(%s);
  if(!ev){res.gone=true;}
  else{
    ev.title=%s;
    ev.startDate=$.NSDate.dateWithTimeIntervalSince1970(%f);
    ev.endDate=$.NSDate.dateWithTimeIntervalSince1970(%f);
    ev.allDay=%s;
    if(store.saveEventSpanError(ev,0,$())){res.ok=true;res.mod=ev.lastModifiedDate.timeIntervalSince1970;}
    else{res.err='save-failed';}
  }
}
JSON.stringify({granted:granted,result:res});"
  "JXA template: %d iters, %s uid, %s title, %f start, %f end, %s allDay.")

(defun org-apple-calendar--eventkit-update-event (uid title start end all-day)
  "Update Apple event UID (title/start/end/all-day). START/END epoch seconds.
Return plist (:ok :mod / :gone / :error)."
  (let* ((script (format org-apple-calendar--update-script-template
                         (* 10 org-apple-calendar-access-timeout)
                         (json-encode uid)
                         (json-encode (or title "(Termin)"))
                         (float start) (float end)
                         (if all-day "true" "false")))
         (data (org-apple-calendar--jxa-run-json script))
         (res (alist-get 'result data)))
    (cond
     ((not (eq (alist-get 'granted data) t)) (list :error "no-access"))
     ((eq (alist-get 'ok res) t) (list :ok t :mod (alist-get 'mod res)))
     ((eq (alist-get 'gone res) t) (list :gone t))
     (t (list :error (or (alist-get 'err res) "unknown"))))))

(defun org-apple-calendar--appointment-differs-p (appt apple)
  "Non-nil when org APPT differs from Apple event APPLE (title/time/all-day).
APPT :start/:end are epoch floats; APPLE :start/:end are Emacs time."
  (or (not (string= (or (plist-get appt :title) "")
                    (or (plist-get apple :title) "")))
      (not (eq (and (plist-get appt :all-day) t)
               (and (plist-get apple :all-day) t)))
      (>= (abs (- (plist-get appt :start)
                  (float-time (plist-get apple :start)))) 60)
      (>= (abs (- (plist-get appt :end)
                  (float-time (plist-get apple :end)))) 60)))

(defun org-apple-calendar--set-entry-timestamp (tsstr)
  "Replace the first active timestamp in the entry at point with TSSTR."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (org-end-of-subtree t t))))
      (if (re-search-forward org-ts-regexp end t)
          (replace-match tsstr t t)
        (end-of-line)
        (insert "\n  " tsstr)))))

(defun org-apple-calendar--pull-into-entry (apple)
  "Update the org heading at point from Apple event APPLE (title/timestamp/mod)."
  (org-edit-headline (or (plist-get apple :title) "(Termin)"))
  (org-apple-calendar--set-entry-timestamp
   (org-apple-calendar--event-timestamp apple))
  (org-set-property "APPLE_MOD"
                    (number-to-string (or (plist-get apple :mod) 0))))

(defun org-apple-calendar--append-pulled-appointment (apple)
  "Append Apple event APPLE as a new linked heading to the source file."
  (with-current-buffer (find-file-noselect org-apple-calendar-source-file)
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (insert (format "* %s\n  :PROPERTIES:\n  :APPLE_EVENT_ID: %s\n  :APPLE_CALENDAR: %s\n  :APPLE_MOD: %s\n  :END:\n  %s\n"
                    (or (plist-get apple :title) "(Termin)")
                    (or (plist-get apple :uid) "")
                    org-apple-calendar-target-calendar
                    (number-to-string (or (plist-get apple :mod) 0))
                    (org-apple-calendar--event-timestamp apple)))))

(defun org-apple-calendar-sync-appointments ()
  "Two-way sync between `calendar.org' and the \"Org\" Apple calendar.

Non-recurring appointments. Per heading: unlinked + timestamp -> create; linked
+ `:APPLE_DELETE: t' -> delete in Apple + remove heading; linked but gone in
Apple -> tag `:apple-deleted:' + `:APPLE_GONE:' (heading kept); linked & differ
-> Apple newer (by modDate) pulls into org, else org pushes to Apple. Finally,
Apple events with no heading are pulled in. Recurring events are matched but
left untouched."
  (interactive)
  (unless (eq org-apple-calendar-write-backend 'eventkit)
    (user-error "Sync requires the EventKit write backend"))
  (let ((file org-apple-calendar-source-file))
    (unless (and file (file-exists-p file))
      (user-error "Set `org-apple-calendar-source-file' (e.g. calendar.org)"))
    (let ((start (time-subtract (current-time) (days-to-time 30)))
          (end (time-add (current-time) (days-to-time 365)))
          (by-uid (make-hash-table :test 'equal))
          (matched (make-hash-table :test 'equal))
          (to-delete '())
          (created 0) (pushed 0) (pulled 0) (deleted 0) (gone 0) (pulled-new 0))
      (dolist (ev (org-apple-calendar-fetch-events start end))
        (when (and (string= (plist-get ev :calendar)
                            org-apple-calendar-target-calendar)
                   (not (gethash (plist-get ev :uid) by-uid)))
          (puthash (plist-get ev :uid) ev by-uid)))
      (with-current-buffer (find-file-noselect file)
        (org-with-wide-buffer
         (org-map-entries
          (lambda ()
            (let* ((uid (org-entry-get nil "APPLE_EVENT_ID"))
                   (del (org-entry-get nil "APPLE_DELETE"))
                   (appt (org-apple-calendar--entry-appointment)))
              (cond
               ((and uid del)
                (puthash uid t matched)   ; don't re-pull the event we're deleting
                (push (cons (point-marker) uid) to-delete))
               ((and (not uid) appt (not (org-entry-get nil "APPLE_GONE")))
                (let ((res (org-apple-calendar--eventkit-create-event
                            (plist-get appt :title) (plist-get appt :start)
                            (plist-get appt :end) (plist-get appt :all-day)
                            (plist-get appt :notes) (plist-get appt :recurrence))))
                  (when (plist-get res :uid)
                    (org-set-property "APPLE_EVENT_ID" (plist-get res :uid))
                    (org-set-property "APPLE_CALENDAR"
                                      org-apple-calendar-target-calendar)
                    (when (plist-get res :mod)
                      (org-set-property "APPLE_MOD"
                                        (number-to-string (plist-get res :mod))))
                    (puthash (plist-get res :uid) t matched)
                    (cl-incf created))))
               (uid
                (puthash uid t matched)
                (let ((apple (gethash uid by-uid)))
                  (cond
                   ((null apple)
                    (unless (org-entry-get nil "APPLE_GONE")
                      (org-toggle-tag "apple-deleted" 'on)
                      (org-set-property "APPLE_GONE" "t")
                      (cl-incf gone)))
                   ((or (plist-get apple :recurring)
                        (and appt (plist-get appt :recurrence)))
                    nil)
                   ((and appt (org-apple-calendar--appointment-differs-p appt apple))
                    (let* ((stored (string-to-number
                                    (or (org-entry-get nil "APPLE_MOD") "0")))
                           (amod (or (plist-get apple :mod) 0)))
                      (if (> amod (+ stored 2))
                          (progn (org-apple-calendar--pull-into-entry apple)
                                 (cl-incf pulled))
                        (let ((res (org-apple-calendar--eventkit-update-event
                                    uid (plist-get appt :title)
                                    (plist-get appt :start) (plist-get appt :end)
                                    (plist-get appt :all-day))))
                          (when (plist-get res :mod)
                            (org-set-property
                             "APPLE_MOD" (number-to-string (plist-get res :mod))))
                          (cl-incf pushed)))))
                   (t (unless (org-entry-get nil "APPLE_MOD")
                        (org-set-property
                         "APPLE_MOD"
                         (number-to-string (or (plist-get apple :mod) 0)))))))))))
          nil nil)
         ;; deferred deletes (after the walk, latest-first)
         (dolist (md (sort to-delete (lambda (a b) (> (marker-position (car a))
                                                      (marker-position (car b))))))
           (org-apple-calendar--eventkit-delete-event (cdr md))
           (goto-char (car md))
           (org-back-to-heading t)
           (delete-region (point) (save-excursion (org-end-of-subtree t t)))
           (cl-incf deleted))
         (save-buffer)))
      ;; pull new Apple events (non-recurring, unmatched)
      (maphash
       (lambda (uid apple)
         (when (and (not (gethash uid matched))
                    (not (plist-get apple :recurring)))
           (org-apple-calendar--append-pulled-appointment apple)
           (cl-incf pulled-new)))
       by-uid)
      (with-current-buffer (find-file-noselect file) (save-buffer))
      (message "Sync: %d created · %d→Apple · %d←Apple · %d new · %d deleted · %d gone"
               created pushed pulled pulled-new deleted gone))))

(provide 'org-apple-calendar)
;;; org-apple-calendar.el ends here
