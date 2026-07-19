module Concierge
  module Admin
    # Browse and curate durable memory — it's a CRM. Humans can pin/unpin and
    # retire notes; pinned/human memory leads the agent's prompt.
    class MemoriesController < BaseController
      def index
        @memories = Concierge::Memory.active.order(updated_at: :desc).limit(200)
      end

      def update
        memory = Concierge::Memory.find(params[:id])
        memory.update!(memory_params)
        redirect_to admin_memories_path
      end

      def destroy
        Concierge::Memory.find(params[:id]).update!(active: false)
        redirect_to admin_memories_path
      end

      private

      def memory_params
        params.require(:memory).permit(:pinned, :body, :category)
      end
    end
  end
end
