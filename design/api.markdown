# OBJECTS

## MessageSummary
Used to produce a list of messages from a conversation without
fully loading the mails (all the messages shown as a header when you load a
conversation, that is all except the last one or the one you click to expand) .
The relevant parts when clicked (full body, mimetypes, To, Cc, Bcc, link to
attachments) can be loaded without reloading what we already have.

- dbId
- numMessages
- lastDate
- subject
- shortAuthors
- attachFileNames
- tags

## Message
Same fields as the MessageSummary plus:

- messageId
- from
- to
- cc
- bcc
- bodyHtml
- bodyPlain
- attachments
- deleted
- draft

## ConversationSummary
These are the entries shown on a tag list.

- dbId
- numMessages
- shortAuthors
- attachFileNames
- subject
- tags
- lastDate

## Conversation
These are show when the user click on a conversation summary on the tag list.

- dbId
- summaries: list of MessageSummary objects ordered by date.
- subject
- tags

## Attachment
- Url (direct)
- dbId
- ctype
- filename
- contentId
- size

The messages list will contain messages and/or messagessummaries (identified by
its "MessageType" field in the JSON data). Usually, the last message of the
Conversation will be a full Message and the rest will be MessageSummary, but
sometimes, for example when the Conversation is the result of a search, other
messages will be full Messages too.

Clicking on a MessageSummary will trigger the load of the full Message. If the
user clicks on the "expand" link, all the messages will be fully loaded.


## Tag
- name
- color
- description

-------------------------------------------------------------------------

# REST API

## /conv
* `GET: /:id/`
    Get a Conversation with the specified id

* `GET: /tag/:tag` (limit=20, page=0, loadDeleted=false)
    Get conversations with the specified tag

* `DELETE: /:id/` (purge=false)
    Delete the conversation: sets the delete tag and sets the tag for all emails inside

* `PUT: /:id/undo/delete/`
    Undelete the conversation and all emails inside

* `POST: /:id/tag/`
    Add tags to the conversation

* `DELETE: /:id/tag/`
    Remove tags

## /message
* `GET: /:id/`
    Get the full Email

* `GET: /:id/raw/`
    Get the original raw email

* `(MISSING) POST: /:id/send`
    Send the email (must have been created as a draft before)

* `POST: /` (draftContent=ApiEmail, userName=string, replyDbId=string)
    Create a new draft (new or reply of another email)

* `POST: /:id/attach (attachment=attachDoc, base64content=contents)`
    Adds an attachment to the specified email (returns the attachment id)

* `DELETE: /:id/attach/ (attachId=string)`
    Removes the specified attachment

* `DELETE: /:id/` (purge=0)
    If purge is 0, set the Email.deleted to true. If purge = 1 removes the email,
    its raw file copy, its attachments, and its conversations if it was the only
    remaining email.

* `PUT: /:id/undo/delete/`
    Email.deleted = false

## /batch
* `POST /trash/empty`
   Purge all conversations and emails marked as deleted.
