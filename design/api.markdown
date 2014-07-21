# OBJECTS

## MessageSummary
XXX update
Used to produce a list of messages from a conversation without
fully loading the mails (all the messages shown as a header when you load a
conversation, that is all except the last one or the one you click to expand) .
The relevant parts when clicked (full body, mimetypes, To, Cc, Bcc, link to
attachments) can be loaded without reloading what we already have.

- Subject
- From
- Date
- Attachment filenames
- First words of the text
- Author avatar icon URL

## Message
Same fields as the MessageSummary plus:

- BodyHtml
- BodyPlain
- Attachment URLs

## ConversationSummary
These are the entries shown on a tag list.

- NumMessages
- Authors
- Attachment filenames
- Subject
- Tags
- Date of the last message

## Conversation
These are show when the user click on a conversation summary on the tag list. 

- Messages: list of MessageSummary and/or Message objects ordered by date.
- Subject
- Tags

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

## /tag
`get: /tag/?name=tagname&limit=50&page=0`
    Get the last ConversationSummary objects for that tagname. The number of
    ConversationSummaries returned would depend on the user configuration.

    GET Parameters: name: tagname
                     limit: max results to return
                     page: skip (limit * this) elements

`(MISSING) post: /tag/create (Tag)`
    Create a new tag name with an optional description and color.

    POST Parameters: name: new tag name
                     description: tag description
                     color: tag color
        

## /conversation
`get: /:id/conversation/`/
    Get a Conversation with the specified id
`(MISSING) delete: /:id/conversation/`
    Delete the conversation (internally: tag all messages as deleted)
`(MISSING) post: /:id/conversation/tags`
    Add tags to the conversation
`(MISSING) delete: /:id/conversation/tags`
    Remove tags from the conversation
`(MISSING) post: /search`
    Search conversations

## /message
`(MISSING) get: /:id/message/`
    Get the full Message
`(MISSING) get: /message/:id/attachments/name`
    Get an attachment
`(MISSING) get: /message/:id/raw`
    Get the original raw message
`(MISSING) post: /message/:id/reply`
    Create a new draft as reply of the message specified (doesnt send)
`(MISSING) post: /message/:id/send`
    Send the message (must have been created as a draft before)
`(MISSING) post: /message/new`
    Create a new draft
`(MISSING) delete: /message/:id`
    Put the "trash" tag to the message or delete from DB and filesystem if
    already on the trash

