# OBJECTS

## MessageSummary
Used to produce a list of messages from a conversation without
fully loading the mails (all the messages shown as a header when you load a
conversation, that is all except the last one or the one you click to expand) .
The relevant parts when clicked (full body, mimetypes, To, Cc, Bcc, link to
attachments) can be loaded without reloading what we already have.

- Subject
- From
- Date
- Attachment filenames
- Tags
- First words of the text
- Author avatar icon URL

## Message
Same fields as the MessageSummary plus:

- BodyHtml
- BodyPlain
- Attachment URLs

## Conversation
These are the entries shown on a tag list (Inbox, Sent, etc). It has:

- Sumaries: list of MessageSummary objects ordered by date
- Date of the last message
- Subject
- Tags
- Attachment filenames

Clicking on a MessageSummary  will display a ConversationList. This object
will have:

- One MessageSummary for every message in the conversation.
- One or more FullMessage snormal ConversationList will have the last
  message as a FullMessage, a ConversationList clicked from a search result will
  have all the messages matching the search as FullMessages

## Tag
- name
- color
- description

-------------------------------------------------------------------------

# REST API

## /tag
`get: /tag/name[/page]`
    Get the last  objects for that tagname. The number of
    ConversationSummaries returned would depend on the user configuration.
`post: /tag/name (Tag)`
    Create a new tag name with an optional description and color.

## /conversation
`get: /conversation/id`
    Get a Conversation with the specified id
`delete: /conversation/id`
    Delete the conversation (internally: tag all messages as deleted)
`post: /conversation/tags`
    Add tags to the conversation
`delete: /conversation/tags`
    Remove tags from the conversation
`post: /conversation/search`
    Search

## /message
`get: /message/id`
    Get the full Message
`get: /message/id/attachments/name`
    Get an attachment
`get: /message/id/raw`
    Get the original raw message
`post: /message/id/reply`
    Create a new draft as reply of the message specified (doesnt send)
`post: /message/id/send`
    Send the message (must have been created as a draft before)
`post: /message/new`
    Create a new draft
`delete: /message/id`
    Put the "trash" tag to the message or delete from DB and filesystem if
    already on the trash

