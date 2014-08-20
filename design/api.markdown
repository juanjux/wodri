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
`get: /tag/?name=NAME&limit=XX&page=YY`
    Get the last ConversationSummary objects for that tagname until limit XX,
    starting from page YY

    GET Parameters: name: tagname
                     limit: max results to return
                     page: skip (limit * this) elements


## /conversation
`get: /:id/conversation/`/
    Get a Conversation with the specified id
`get: /:id/conversationdelete/`
    Delete the conversation: sets the delete tag and sets the tag 
    for all emails inside
`get: /:id/conversationundelete/`
    Undelete the conversation and all emails inside
`post: /:id/conversationaddtag`
    Add tags to the conversation
`post: /:id/conversationremovetag`
    Remove tags from the conversation
`post: /conversation/search`
    Search conversations

## /email
`get: /:id/email/`
    Get the full Email
`get: /:id/raw/`
    Get the original raw email
`(MISSING) post: /email/:id/send`
    Send the email (must have been created as a draft before)
`(MISSING) post: /email/draft`
    Create a new draft (new or reply of another email)
`(MISSING) post: /email/draftdiscard`
    Discard a draft (delete from DB and delete attachments)
`(MISSING) post: /email/:id/addattach
    Adds an attachment to the specified email (useful to start uploading the
    attachments while the draft is being edited).
`get: /:id/emaildelete/`
    Email.deleted = true
`get: /:id/emailpurge/`
    Completely remove the email from the system. It'll also remove the
    conversation the email belongs to if it's the last email in it.
`get: /:id/emailundelete/`
    Email.deleted = false
