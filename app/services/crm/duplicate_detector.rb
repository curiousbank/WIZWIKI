module Crm
  class DuplicateDetector
    MINIMUM_SCORE = 60

    def self.call(record)
      new(record).call
    end

    def initialize(record)
      @record = record
    end

    def call
      return DuplicateCandidate.none unless record.persisted?

      candidates.each_with_object([]) do |candidate, matches|
        score, reasons = score_candidate(candidate)
        next if score < MINIMUM_SCORE

        matches << upsert_candidate(candidate, score, reasons)
      end.compact
    end

    private

    attr_reader :record

    def candidates
      record.organization.crm_records
        .where(record_type: record.record_type)
        .where.not(id: record.id)
        .where(candidate_conditions)
        .limit(25)
    end

    def candidate_conditions
      conditions = []
      values = {}

      if record.email.present?
        conditions << "email = :email"
        values[:email] = record.email
      end

      if record.phone.present?
        conditions << "phone = :phone"
        values[:phone] = record.phone
      end

      if record.domain.present?
        conditions << "domain = :domain"
        values[:domain] = record.domain
      end

      if record.name.present?
        conditions << "LOWER(name) = :name"
        values[:name] = record.name.downcase
      end

      return ["1=0"] if conditions.empty?

      [conditions.join(" OR "), values]
    end

    def score_candidate(candidate)
      reasons = []
      score = 0

      if record.email.present? && record.email == candidate.email
        score += 100
        reasons << "email exact match"
      end

      if record.domain.present? && record.domain == candidate.domain
        score += record.record_type == "company" ? 100 : 40
        reasons << "domain exact match"
      end

      if record.phone.present? && record.phone == candidate.phone
        score += 75
        reasons << "phone exact match"
      end

      if record.name.to_s.casecmp(candidate.name.to_s).zero?
        score += record.record_type.in?(%w[deal ticket]) ? 70 : 45
        reasons << "name exact match"
      end

      [score.clamp(0, 100), reasons]
    end

    def upsert_candidate(candidate, score, reasons)
      DuplicateCandidate.find_or_initialize_by(
        organization: record.organization,
        crm_record: record,
        duplicate_record: candidate
      ).tap do |duplicate|
        duplicate.score = score
        duplicate.reasons = reasons
        duplicate.status = "open" if duplicate.status.blank?
        duplicate.save!
      end
    end
  end
end
