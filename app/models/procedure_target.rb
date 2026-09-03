class ProcedureTarget < ApplicationRecord
  TARGET_TYPES = %w[label product inbox pipeline_stage].freeze

  belongs_to :procedure

  validates :target_type, presence: true, inclusion: { in: TARGET_TYPES }
  validates :target_id, presence: true
  validates :target_type, uniqueness: { scope: [:procedure_id, :target_id] }
end
