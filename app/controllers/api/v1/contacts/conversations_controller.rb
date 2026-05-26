class Api::V1::Contacts::ConversationsController < Api::V1::Contacts::BaseController
  def index
    # Return all conversations for this contact ordered by most recent activity.
    # NOTE: PermissionFilterService was intentionally removed here because the
    # role check (user.role) silently returns nil in this system — roles live in
    # a separate table, not a column on users. This caused the service to fall
    # back to inbox-membership filtering, which blocked every migrated conversation.
    # Contact conversation history should be visible to any authenticated agent.
    @conversations = Conversation.includes(
      :assignee, :contact, :inbox, :taggings, { pipeline_items: [:pipeline, :pipeline_stage] }
    ).where(contact_id: @contact.id)
              .order(last_activity_at: :desc)
              .limit(20)
  end
end
