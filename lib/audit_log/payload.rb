# frozen_string_literal: true

module AuditLog
  # The collector AuditLog.audited yields. It exists so a narrative payload can
  # be built in two places -- identity and inputs eagerly, beside the action
  # name; outcomes inside the block, after the writes that produce them.
  #
  # It WRAPS a Hash rather than subclassing one, deliberately. Subclassing gets
  # []=, merge! and every other Hash method for free, and publishes `delete`,
  # `clear`, `replace` and `reject!` as part of what a block may do to an audit
  # payload -- the same argument that keeps Timeline::Activity from being an
  # ActiveRecord::Base, on a smaller object. Six methods and one tombstone is the
  # whole surface; anything else is a decision somebody makes later, on purpose.
  class Payload
    # Keys are normalised to symbols on the way in. Not cosmetic: EventSubscriber
    # symbolizes at write time, so `audit["order_id"] = x` against an eager
    # `order_id:` would arrive as two keys, collapse to one there, and silently
    # take whichever landed last -- an overwrite that walks straight past the
    # guard below.
    def initialize(action, eager = {})
      @action = action
      @hash   = eager.to_h.transform_keys(&:to_sym)
      @eager  = @hash.keys.freeze
    end

    def []=(key, value)
      key = key.to_sym
      reject_eager_overwrite!(key)
      @hash[key] = value
    end

    # merge!({...}) and merge!(k: v) both, because supporting both costs one
    # optional positional and a developer should not have to remember which.
    def merge!(hash = nil, **kwargs)
      incoming = {}
      incoming.merge!(hash.to_h.transform_keys(&:to_sym)) if hash
      # kwargs, not just the positional hash: Ruby 3 admits non-Symbol keys in
      # keyword arguments, so merge!("total_cents" => 500) arrives here as a
      # string-keyed kwarg and would otherwise dodge the normalisation above.
      incoming.merge!(kwargs.transform_keys(&:to_sym))

      incoming.each_key { |key| reject_eager_overwrite!(key) }
      @hash.merge!(incoming)
      self
    end

    def [](key)     = @hash[key.to_sym]
    def key?(key)   = @hash.key?(key.to_sym)
    def to_h        = @hash.dup

    # A tombstone, not an oversight. Ruby's convention is that `merge` returns a
    # new hash and leaves the receiver alone, so on a collector it is a silent
    # under-report: the keys are computed, discarded, and the event emits without
    # them while the summary renders a gap and nothing raises. There is no
    # spelling of []= with the same trap, which is why that one needs no tombstone.
    def merge(*)
      raise Error, "AuditLog::Payload#merge would build a hash and discard it, " \
                   "emitting the event without those keys. Use merge! (or audit[:key] = value)."
    end

    def inspect = "#<AuditLog::Payload #{@action.inspect} #{@hash.inspect}>"

    private

    # An eager key that the block also sets is never a legitimate overwrite: if
    # the block changes the value, the value belonged in the block. So the
    # message names the fix rather than reporting the collision -- this is the
    # one place the eager/lazy rule can be taught at the moment it is broken.
    def reject_eager_overwrite!(key)
      return unless @eager.include?(key)

      raise Error, "AuditLog.audited(#{@action.inspect}): #{key.inspect} was passed as a " \
                   "keyword argument AND set inside the block. Keyword arguments are " \
                   "evaluated before the block runs, so the keyword holds the PRE-WRITE " \
                   "value. Remove it from the keywords -- identity and inputs go there, " \
                   "outcomes go in the block."
    end
  end
end
