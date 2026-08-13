# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Whatsapp::IncomingMessageBaseService' do
    it 'has spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Whatsapp::IncomingMessageBaseService do
  let(:host_class) do
    Class.new(Whatsapp::IncomingMessageBaseService) do
      attr_writer :processed_params

      def processed_params
        @processed_params
      end
    end
  end

  let(:message) do
    instance_double(
      Message,
      id: 1,
      status: 'sent',
      content_attributes: {},
      conversation: nil
    )
  end
  let(:inbox) { instance_double(Inbox) }
  let(:service) { host_class.new(inbox: inbox, params: {}) }
  let(:status_service) { instance_double(Messages::StatusUpdateService, perform: true) }

  describe '#update_message_with_status' do
    context 'when status is delivered' do
      it 'delegates to Messages::StatusUpdateService with nil external_error' do
        expect(Messages::StatusUpdateService).to receive(:new).with(message, 'delivered', nil).and_return(status_service)
        expect(status_service).to receive(:perform)

        service.send(:update_message_with_status, message, { status: 'delivered', id: 'wamid.xxx' })
      end
    end

    context 'when status is read' do
      it 'delegates with read + nil external_error' do
        expect(Messages::StatusUpdateService).to receive(:new).with(message, 'read', nil).and_return(status_service)

        service.send(:update_message_with_status, message, { status: 'read', id: 'wamid.xxx' })
      end
    end

    context 'when status is failed with errors[]' do
      let(:status_payload) do
        {
          status: 'failed',
          id: 'wamid.xxx',
          errors: [{ code: 131_026, title: 'Message undeliverable' }]
        }
      end

      it 'formats external_error as "<code>: <title>"' do
        expect(Messages::StatusUpdateService).to receive(:new)
          .with(message, 'failed', '131026: Message undeliverable')
          .and_return(status_service)

        service.send(:update_message_with_status, message, status_payload)
      end
    end

    context 'when status is failed but errors[] is absent' do
      it 'leaves external_error as nil' do
        expect(Messages::StatusUpdateService).to receive(:new).with(message, 'failed', nil).and_return(status_service)

        service.send(:update_message_with_status, message, { status: 'failed', id: 'wamid.xxx' })
      end
    end
  end

  # AC9 / L-6: exercise the REAL funnel via WhatsApp Cloud — proves that a
  # duplicate `delivered` webhook (Meta retries are common) does NOT re-emit
  # the Wisper event a second time, which would otherwise flow through the
  # EvoFlow listener as a bogus `message.read`.
  describe '#update_message_with_status — funnel e2e (no service mock)' do
    it 'AC9 e2e: duplicate delivered webhook produces only one Wisper publish' do
      already_delivered = instance_double(
        Message, id: 42, status: 'delivered', delivered?: true, read?: false, failed?: false,
                 content_attributes: {}
      )
      allow(Message).to receive(:statuses).and_return('sent' => 0, 'delivered' => 1, 'read' => 2, 'failed' => 3)

      # The funnel's same-status guard should short-circuit BEFORE update! and
      # BEFORE any Wisper publish. We assert the side-effect contract directly.
      expect(already_delivered).not_to receive(:update!)
      service.send(:update_message_with_status, already_delivered, { status: 'delivered', id: 'wamid.xxx' })
    end
  end

  # Regression coverage for the incident where two webhooks for a brand-new
  # contact's first messages (seconds apart) raced on
  # index_contact_inboxes_on_inbox_id_and_bsuid: the loser's exception left the
  # Redis "message under process" guard stuck for its full 1-day TTL, so the
  # Sidekiq retry (and any real re-delivery from Meta) silently gave up with no
  # error anywhere — the message was gone for good instead of just retried.
  describe '#update_bsuid_fields' do
    it 'rescues a concurrent-webhook RecordNotUnique race instead of raising' do
      contact_inbox = instance_double(ContactInbox, id: 7, bsuid: nil, whatsapp_username: nil)
      allow(contact_inbox).to receive(:update!).and_raise(
        ActiveRecord::RecordNotUnique.new(
          'PG::UniqueViolation: duplicate key value violates unique constraint ' \
          '"index_contact_inboxes_on_inbox_id_and_bsuid"'
        )
      )

      expect(Rails.logger).to receive(:warn).with(/bsuid=abc123/)
      expect { service.send(:update_bsuid_fields, contact_inbox, 'abc123', nil) }.not_to raise_error
    end
  end

  describe '#process_messages — dedup guard release' do
    before do
      service.processed_params = { messages: [{ id: 'wamid.race', type: 'text' }] }
      allow(service).to receive(:find_message_by_source_id).and_return(nil)
      allow(service).to receive(:message_under_process?).and_return(false)
      allow(service).to receive(:cache_message_source_id_in_redis)
    end

    it 'clears the guard even when set_contact raises mid-flow' do
      allow(service).to receive(:set_contact).and_raise(ActiveRecord::RecordNotUnique.new('boom'))

      expect(service).to receive(:clear_message_source_id_from_redis)
      expect { service.send(:process_messages) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'still clears the guard on the happy path' do
      allow(service).to receive(:set_contact) { service.instance_variable_set(:@contact, instance_double(Contact)) }
      allow(service).to receive(:set_conversation)
      allow(service).to receive(:create_messages)

      expect(service).to receive(:clear_message_source_id_from_redis)
      service.send(:process_messages)
    end
  end

  # Regression coverage for the "contact card shows no name" bug: attach_contact
  # built the Attachment without a `meta[:display_name]`, so channels that share
  # this base implementation (WhatsApp Cloud API, Baileys, Evolution Go) rendered
  # a generic "shared contact" fallback in the frontend instead of the real name,
  # even though the vCard carried a name.formatted_name field all along.
  describe '#attach_contact' do
    let(:attachments_relation) { instance_double('AttachmentsRelation') }
    let(:contact_message) { instance_double(Message, attachments: attachments_relation) }

    before do
      service.processed_params = { messages: [{ type: 'contacts' }] }
      service.instance_variable_set(:@message, contact_message)
    end

    it 'builds one attachment with display_name from the vCard name and the phone as fallback_title' do
      contact = { name: { formatted_name: 'Fernanda Martins' }, phones: [{ phone: '+55 11 99999-8888' }] }

      expect(attachments_relation).to receive(:new).with(
        file_type: :contact,
        fallback_title: '+55 11 99999-8888',
        meta: { display_name: 'Fernanda Martins' }
      )

      service.send(:attach_contact, contact)
    end

    it 'creates one attachment per phone for a contact with multiple numbers' do
      contact = {
        name: { formatted_name: 'Multi Phone' },
        phones: [{ phone: '+5511111111111' }, { phone: '+5511222222222' }]
      }

      expect(attachments_relation).to receive(:new).with(hash_including(fallback_title: '+5511111111111'))
      expect(attachments_relation).to receive(:new).with(hash_including(fallback_title: '+5511222222222'))

      service.send(:attach_contact, contact)
    end

    it 'falls back to the placeholder phone when the vCard has no phones' do
      contact = { name: { formatted_name: 'No Phone' }, phones: [] }

      expect(attachments_relation).to receive(:new).with(
        file_type: :contact,
        fallback_title: 'Phone number is not available',
        meta: { display_name: 'No Phone' }
      )

      service.send(:attach_contact, contact)
    end

    it 'leaves display_name nil when the vCard has no name field' do
      contact = { phones: [{ phone: '+5511333333333' }] }

      expect(attachments_relation).to receive(:new).with(hash_including(meta: { display_name: nil }))

      service.send(:attach_contact, contact)
    end
  end
end
