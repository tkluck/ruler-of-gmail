# Ruler of Gmail

Sieve for Gmail but really just Perl transforming it to filters specified in GMail's XML format.

So the company I work for switched from a Linux-based mail stack, first to Microsoft's Exchange product, then to GMail... We used to have Sieve filters available, but that went away with the move, and Exchange only has its stupid rule editor. Even worse, GMail doesn't have any scriptable language at all.

This is  fork of ruler-of-exchange that uses a similar language to power GMail filters. The main win is that GMail's filters do not support 'last-action', so every email will be matched against every filter. Here, we emulate 'last-action' behaviour by negating last-action's filters in all subsequent matches.

## Usage

    ./upload.pl -c <config file>

## Config format

    name "John Doe";
    email "name@gmail.com";

    label INBOX {
        label Important { }
        label Spam { }
    }

    match recipient "name@gmail.com" {
        last-action apply-label INBOX/Important;
    }

    match from "hr@example.com" {
        match subject "compliance" {
           action setread;
           last-action move INBOX/Spam;
        }
    }

### Format

There are two allowed top-level settings, `name` and `email`. When both are present, these will be added as metadata to the xml output.

There are two block types, which are both allowed to recurse, `label` and `match`.

`label` specifies your label structure. It is recommended to start with a definition for your inbox, and create your other labels in there. Label blocks do not currently allow specifying any settings other than the name. When specifying labels in rules, their names are recursively joined using a `/` (forward slash).

    label Inbox {
        label MyLabel { } # Becomes "Inbox/MyLabel"
        label AnotherLabel { } # Becomes "Inbox/AnotherLabel"
    }

`match` specifies your filter structure. After the `match` keyword, its expression follows (see the "Expressions" section), following with a bracket (`{`) indicating the start of its body. Within this body more `match` blocks may be created, applying an effective `AND` to your filters.

    match subject "[Spam]" {
        action delete;
    }

Within a `match` block actions may be specified. For information about these, see the "Actions" section.

A note on quoting: it is optional to quote strings that do not contain whitespace, semicolons (`;`), or brackets (`{`, `[`, `]`, `}`). If needed, escaping operations can be done using the usual backslash (`\`).

## Expressions

Five types of expressions are currently implemented, plus their negated versions (specified using a `not` after `match`).

    # Matches mails that contain "Tom" or "Code" in the subject
    match subject ["Tom" "Code"] { }
    # Others:
    match recipient "my.mail@example.com" { 
    match not from "ceo@example.com" { } # Note the negation
    # match subject or body
    match text [ "Hello World" "Just testing" ] { }
    # match list id
    match list "commits.lists.example.com"

## Actions

Actions are indicated using the `action` and `last-action` keywords. In case of `last-action`, rule processing will stop after the action is executed.

Five actions are currently implemented :

 - `delete`: deletes the message
 - `apply-label <label>`: moves the message to a label. The label must be configured using a `label` block
 - `setread`: marks the message as read
 - `skip-inbox`: makes the message move to 'all mail' directly
 - `move <label>`: combination of `apply-label` and `skip-inbox`

## Caveats

 - This software was implemented in a very short amount of time, bugs can happen

## License

This is free open-source software. For more details, see `LICENSE`
